/**
 * Chain component — constrains two atom/movables by a physical chain with a fixed maximum path length.
 *
 * The chain wraps around walls and obstacles by tracking a list of bend nodes (turfs the chain
 * corners around). No pathfinding is used: bends accumulate as the endpoints move and are pruned
 * when the straight-line path between adjacent nodes becomes clear again.
 *
 * Tautness is measured as total path length (sum of get_dist() between consecutive nodes).
 * When taut:
 *   - A dynamic (non-anchored) anchor with low move_resist is pulled along.
 *   - A throw into a static/resistant anchor causes whiplash on the thrown movable.
 *   - Enough force breaks the chain entirely.
 *   - Walking into a taut chain is simply blocked.
 *
 * COMPONENT_DUPE_ALLOWED — an object may have multiple chains.
 */
/datum/component/chain
	dupe_mode = COMPONENT_DUPE_ALLOWED

	/// The other end of the chain.
	var/atom/movable/anchor
	/// Maximum total path length in tiles before the chain goes taut.
	var/max_length = CHAIN_LENGTH_DEFAULT
	/// Force needed to snap the chain.
	var/break_force = CHAIN_BREAK_FORCE_DEFAULT
	/// Display name used in player messages.
	var/chain_name = "chain"
	/// Weakref to the /obj/item/chain that spawned this component (may be null).
	var/datum/weakref/chain_item_ref
	/**
	 * Ordered list of /turf representing the bend corners the chain passes through.
	 * Does NOT include the endpoints (anchor.loc and parent.loc).
	 * Full path: [anchor.loc] → bend_nodes[1..n] → [parent.loc]
	 */
	var/list/bend_nodes
	/// Cached total tile distance along the current path. Updated on every move.
	var/total_path_length = 0
	/**
	 * Lazily-keyed assoc list: turf → /obj/effect/chain_node for every turf currently
	 * occupied by a visual segment.  Sparse: only holds turfs that have a node object.
	 */
	var/list/node_effects
	/**
	 * List of /obj/effect/chain_node (is_slack=TRUE) stacked at the parent endpoint's turf.
	 * Count always equals max_length - total_path_length (the unused slack length).
	 */
	var/list/slack_effects
	/// Variable movespeed modifier applied to parent mob endpoint. Null if parent is not a mob.
	var/datum/movespeed_modifier/chained/parent_speed_mod
	/// Variable movespeed modifier applied to anchor mob endpoint. Null if anchor is not a mob.
	var/datum/movespeed_modifier/chained/anchor_speed_mod
	/// The mob currently carrying the parent endpoint (parent is in their inventory). Null if on the floor.
	var/mob/parent_carrier
	/// The mob currently carrying the anchor endpoint (anchor is in their inventory). Null if on the floor.
	var/mob/anchor_carrier

/datum/component/chain/Initialize(atom/movable/new_anchor, new_max_length = CHAIN_LENGTH_DEFAULT, \
	new_break_force = CHAIN_BREAK_FORCE_DEFAULT, new_chain_name = "chain", datum/weakref/item_ref = null)

	if(!ismovable(parent))
		return COMPONENT_INCOMPATIBLE
	if(QDELETED(new_anchor) || !istype(new_anchor))
		return COMPONENT_INCOMPATIBLE

	// Refuse to attach if the initial straight-line path is blocked by a wall or dense obstacle.
	var/turf/a_turf = get_turf(new_anchor)
	var/turf/p_turf = get_turf(parent)
	if(a_turf && p_turf && a_turf != p_turf)
		var/list/init_line = get_line(a_turf, p_turf)
		for(var/i in 2 to length(init_line) - 1)
			var/turf/T = init_line[i]
			if(T.density)
				return COMPONENT_INCOMPATIBLE
			for(var/atom/movable/AM in T)
				if(AM.density)
					return COMPONENT_INCOMPATIBLE

	anchor = new_anchor
	max_length = new_max_length
	break_force = new_break_force
	chain_name = new_chain_name
	chain_item_ref = item_ref
	bend_nodes = list()
	node_effects = list()
	slack_effects = list()
	total_path_length = get_dist(parent, anchor)
	ADD_TRAIT(parent, TRAIT_CHAINED, REF(src))
	if(ismovable(anchor))
		ADD_TRAIT(anchor, TRAIT_CHAINED, REF(src))
	// Apply movespeed modifiers to mob endpoints so they slow down as the chain becomes taut.
	if(ismob(parent))
		var/mob/parent_mob = parent
		parent_speed_mod = new /datum/movespeed_modifier/chained()
		parent_mob.add_movespeed_modifier(parent_speed_mod)
	if(ismovable(anchor) && ismob(anchor))
		var/mob/anchor_mob = anchor
		anchor_speed_mod = new /datum/movespeed_modifier/chained()
		anchor_mob.add_movespeed_modifier(anchor_speed_mod)
	spawn_all_nodes()

/datum/component/chain/Destroy()
	despawn_all_nodes()
	// Remove movespeed modifiers from mob endpoints.
	if(parent_speed_mod)
		if(!QDELETED(parent) && ismob(parent))
			var/mob/parent_mob = parent
			parent_mob.remove_movespeed_modifier(parent_speed_mod)
		qdel(parent_speed_mod)
		parent_speed_mod = null
	if(anchor_speed_mod)
		if(!QDELETED(anchor) && ismob(anchor))
			var/mob/anchor_mob = anchor
			anchor_mob.remove_movespeed_modifier(anchor_speed_mod)
		qdel(anchor_speed_mod)
		anchor_speed_mod = null
	if(!QDELETED(parent))
		REMOVE_TRAIT(parent, TRAIT_CHAINED, REF(src))
	if(!QDELETED(anchor))
		REMOVE_TRAIT(anchor, TRAIT_CHAINED, REF(src))
	anchor = null
	bend_nodes = null
	node_effects = null
	slack_effects = null
	chain_item_ref = null
	// Clean up any carrier signal registrations that UnregisterFromParent won't reach
	// because the carrier mobs are not this component's parent or anchor.
	if(parent_carrier && !QDELETED(parent_carrier))
		UnregisterSignal(parent_carrier, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
	parent_carrier = null
	if(anchor_carrier && !QDELETED(anchor_carrier))
		UnregisterSignal(anchor_carrier, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
	anchor_carrier = null
	return ..()

/datum/component/chain/RegisterWithParent()
	RegisterSignal(parent, COMSIG_MOVABLE_PRE_MOVE, PROC_REF(on_end_pre_move))
	RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_end_moved))
	RegisterSignal(parent, COMSIG_QDELETING, PROC_REF(on_end_deleted))
	if(isitem(parent))
		RegisterSignal(parent, COMSIG_ITEM_PICKUP, PROC_REF(on_end_picked_up))
		RegisterSignal(parent, COMSIG_ITEM_DROPPED, PROC_REF(on_end_dropped))
	if(ismovable(anchor))
		RegisterSignal(anchor, COMSIG_MOVABLE_PRE_MOVE, PROC_REF(on_end_pre_move))
		RegisterSignal(anchor, COMSIG_MOVABLE_MOVED, PROC_REF(on_end_moved))
		RegisterSignal(anchor, COMSIG_QDELETING, PROC_REF(on_end_deleted))
		if(isitem(anchor))
			RegisterSignal(anchor, COMSIG_ITEM_PICKUP, PROC_REF(on_end_picked_up))
			RegisterSignal(anchor, COMSIG_ITEM_DROPPED, PROC_REF(on_end_dropped))

/datum/component/chain/UnregisterFromParent()
	UnregisterSignal(parent, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED, COMSIG_QDELETING, COMSIG_ITEM_PICKUP, COMSIG_ITEM_DROPPED))
	if(!QDELETED(anchor) && ismovable(anchor))
		UnregisterSignal(anchor, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED, COMSIG_QDELETING, COMSIG_ITEM_PICKUP, COMSIG_ITEM_DROPPED))
	// Unregister from any carriers that picked up an endpoint.
	if(parent_carrier && !QDELETED(parent_carrier))
		UnregisterSignal(parent_carrier, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
		parent_carrier = null
	if(anchor_carrier && !QDELETED(anchor_carrier))
		UnregisterSignal(anchor_carrier, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
		anchor_carrier = null

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/**
 * Returns the full ordered list of turfs representing the current chain path,
 * including both endpoints.
 */
/datum/component/chain/proc/get_full_path()
	var/turf/parent_turf = get_turf(parent)
	var/turf/anchor_turf = get_turf(anchor)
	if(!parent_turf || !anchor_turf)
		return list()
	var/list/path = list(anchor_turf)
	path += bend_nodes.Copy()
	path += parent_turf
	return path

/**
 * Expands the sparse waypoint list from get_full_path() into a tile-by-tile turf list
 * using get_line() for each segment between consecutive waypoints.
 * This is used for visual node placement so every tile on the chain path gets a node,
 * not just the bend corners and endpoints.
 */
/datum/component/chain/proc/get_visual_path()
	var/list/waypoints = get_full_path()
	var/n = length(waypoints)
	if(n < 2)
		return waypoints.Copy()
	var/list/result = list(waypoints[1])
	for(var/i in 1 to n - 1)
		var/list/seg = get_line(waypoints[i], waypoints[i + 1])
		for(var/j in 2 to length(seg))
			result += seg[j]
	return result

/**
 * Computes the total tile distance along a given ordered turf list.
 */
/datum/component/chain/proc/path_length(list/path)
	var/len = 0
	for(var/i in 1 to length(path) - 1)
		len += get_dist(path[i], path[i + 1])
	return len

/**
 * Recomputes total_path_length from the current state of the path.
 */
/datum/component/chain/proc/recalc_length()
	total_path_length = path_length(get_full_path())

/**
 * Returns the index into the full path list that corresponds to the given endpoint
 * (either parent or anchor).  Returned as a path-list index, not a bend_nodes index.
 * The full path is: index 1 = anchor, 2..n-1 = bend_nodes, n = parent.
 */
/datum/component/chain/proc/end_index_in_path(atom/movable/endpoint)
	if(endpoint == parent)
		return length(bend_nodes) + 2  // last slot
	return 1                            // anchor is always first

/**
 * Returns the neighbour node in the full path that is adjacent to the given endpoint.
 * For parent → the last bend node (or anchor_turf if bend_nodes is empty).
 * For anchor → the first bend node (or parent_turf if bend_nodes is empty).
 */
/datum/component/chain/proc/neighbour_of(atom/movable/endpoint)
	var/turf/anchor_turf = get_turf(anchor)
	var/turf/parent_turf = get_turf(parent)
	if(endpoint == parent)
		return (length(bend_nodes) > 0) ? bend_nodes[length(bend_nodes)] : anchor_turf
	else
		return (length(bend_nodes) > 0) ? bend_nodes[1] : parent_turf

/**
 * Returns the second neighbour (two hops away) from the given endpoint in the full path.
 * Used for unwrap checks.  Returns null if the path is too short.
 */
/datum/component/chain/proc/second_neighbour_of(atom/movable/endpoint)
	if(endpoint == parent)
		if(length(bend_nodes) >= 2)
			return bend_nodes[length(bend_nodes) - 1]
		else if(length(bend_nodes) == 1)
			return get_turf(anchor)
	else
		if(length(bend_nodes) >= 2)
			return bend_nodes[2]
		else if(length(bend_nodes) == 1)
			return get_turf(parent)
	return null

/**
 * Checks whether the straight line between two turfs passes through any dense obstacle.
 * Returns TRUE if any turf on the line (excluding the endpoints themselves) is dense
 * or contains a dense, non-passable object.
 */
/datum/component/chain/proc/line_is_blocked(turf/a, turf/b)
	var/list/line = get_line(a, b)
	for(var/i in 2 to length(line) - 1)
		var/turf/T = line[i]
		if(T.density)
			return TRUE
		for(var/atom/movable/AM in T)
			if(AM.density)
				return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Wrap / unwrap logic
// ---------------------------------------------------------------------------

/**
 * Called after a successful move of one endpoint.
 * Checks whether the chain just went around a corner (wrap) or whether a bend
 * that was previously necessary can be straightened out (unwrap).
 *
 * Arguments:
 * - mover: the endpoint that just moved
 * - old_loc: the turf the mover was on before the move
 *
 * Returns the index range (start, end) into the full path that was dirtied,
 * stored as a list(start_idx, end_idx) for update_chain_visuals().
 */
/datum/component/chain/proc/update_path_after_move(atom/movable/mover, turf/old_loc)
	var/turf/new_loc = get_turf(mover)
	if(!new_loc || !old_loc)
		return null

	var/is_parent = (mover == parent)
	var/turf/neighbour = neighbour_of(mover)
	var/turf/second_neighbour = second_neighbour_of(mover)

	// --- Wrap check ---
	// If the straight line from new_loc back to our neighbour is now blocked, the chain
	// must have bent around something.  Record old_loc as a new bend corner.
	var/wrapped = FALSE
	if(line_is_blocked(new_loc, neighbour))
		if(is_parent)
			bend_nodes += old_loc
		else
			bend_nodes.Insert(1, old_loc)
		recalc_length()
		wrapped = TRUE

	// --- Unwrap check ---
	// Skipped if we just wrapped this step — otherwise wrap+unwrap cancel each other and
	// the bend node is immediately removed, preventing corners from being recorded.
	// If there is a bend node adjacent to this endpoint, and the straight line from
	// new_loc all the way to the node beyond it is now clear, remove that intermediate bend.
	if(!wrapped && second_neighbour)
		if(!line_is_blocked(new_loc, second_neighbour))
			// Remove the now-redundant intermediate bend node
			if(is_parent)
				bend_nodes.Remove(bend_nodes[length(bend_nodes)])
			else
				bend_nodes.Remove(bend_nodes[1])
			recalc_length()

// ---------------------------------------------------------------------------
// PRE_MOVE signal — tautness enforcement
// ---------------------------------------------------------------------------

/**
 * Fired on COMSIG_MOVABLE_PRE_MOVE for both endpoints.
 * Determines whether the attempted move would exceed max_length, and if so,
 * applies the appropriate response: break, pull, whiplash, or block.
 */
/datum/component/chain/proc/on_end_pre_move(atom/movable/mover, atom/entering_loc)
	SIGNAL_HANDLER
	if(QDELETED(anchor) || QDELETED(parent))
		snap()
		return

	// Build the path as it would be after this move, keeping existing bend_nodes.
	// Worst-case path length doesn't shrink from a move that goes taut, so we can
	// check against the straight dist from new_loc to nearest node for a fast early-out.
	var/turf/new_loc = get_turf(entering_loc)
	if(!new_loc)
		return

	var/atom/movable/other_end = (mover == parent) ? anchor : parent
	var/turf/neighbour = neighbour_of(mover)

	// Fast slack check: if the move keeps the endpoint close to its neighbour,
	// we almost certainly have slack.  Only bother with the full sum if it's borderline.
	var/new_dist_to_neighbour = get_dist(new_loc, neighbour)
	// Compute what the total path length would be after the move.
	var/old_end_dist = get_dist(get_turf(mover), neighbour)
	var/new_total = total_path_length - old_end_dist + new_dist_to_neighbour
	if(new_total <= max_length)
		return // still has slack, allow
	if(new_total < total_path_length)
		return // reducing tension (moving toward the other end) — allow

	// Chain would become taut. Determine the effective tug force.
	var/tug_force
	if(!QDELETED(mover.throwing))
		tug_force = mover.throwing.force * (mover.mass / MASS_DEFAULT)
	else
		tug_force = mover.move_force

	// --- Break ---
	if(tug_force >= break_force)
		snap()
		return // allow the move through (chain is gone)

	// Fire taut signal on both ends before deciding what to do.
	SEND_SIGNAL(parent, COMSIG_MOVABLE_CHAIN_TAUT, src)
	SEND_SIGNAL(anchor, COMSIG_MOVABLE_CHAIN_TAUT, src)

	// --- Pull the other end (dynamic anchor with low resist) ---
	if(!other_end.anchored && tug_force >= other_end.move_resist)
		if(!QDELETED(mover.throwing))
			// Transfer the throw momentum to the other end in roughly the same direction.
			var/dir_away = get_dir(get_turf(mover), new_loc)
			var/turf/pull_target = get_step(get_turf(other_end), dir_away)
			if(pull_target)
				other_end.throw_at(pull_target, \
					max(1, round(mover.throwing.maxrange * (MASS_DEFAULT / max(other_end.mass, 1)))), \
					mover.throwing.speed, \
					mover, \
					force = mover.throwing.force)
		else
			var/dir_toward = get_dir(get_turf(other_end), get_turf(mover))
			other_end.Move(get_step(get_turf(other_end), dir_toward), dir_toward)
		return COMPONENT_MOVABLE_BLOCK_PRE_MOVE

	// --- Whiplash (throw into static/resistant anchor) ---
	if(!QDELETED(mover.throwing))
		var/datum/thrownthing/original_throw = mover.throwing
		// Block the move first; SSthrowing will call finalize() on the throw.
		// After the throw resolves, bounce the mover back.
		addtimer(CALLBACK(src, PROC_REF(do_whiplash), mover, original_throw), 0)
		return COMPONENT_MOVABLE_BLOCK_PRE_MOVE

	// --- Block walking into a taut chain ---
	var/atom/movable/mover_mob = mover
	if(ismob(mover_mob))
		mover_mob.balloon_alert(mover_mob, "[chain_name] goes taut!")
	return COMPONENT_MOVABLE_BLOCK_PRE_MOVE

/**
 * Perform a whiplash bounce-back throw on the given mover.
 * Called asynchronously after the original throw has been finalized.
 */
/datum/component/chain/proc/do_whiplash(atom/movable/mover, datum/thrownthing/original_throw)
	if(QDELETED(mover) || QDELETED(src))
		return
	var/turf/mover_turf = get_turf(mover)
	if(!mover_turf)
		return
	// Throw in the reverse direction (back toward where it came from).
	var/turf/anchor_turf = get_turf(anchor)
	var/away_dir = get_dir(anchor_turf, mover_turf) // direction away from anchor
	var/turf/away_target = get_step(mover_turf, away_dir)
	if(!away_target)
		away_target = mover_turf
	var/whiplash_force = original_throw.force * CHAIN_WHIPLASH_FORCE_RATIO
	mover.throw_at(away_target, CHAIN_WHIPLASH_RANGE, mover.throw_speed, force = whiplash_force)
	SEND_SIGNAL(mover, COMSIG_MOVABLE_CHAIN_WHIPLASH, original_throw)

// ---------------------------------------------------------------------------
// POST_MOVE signal — wrap/unwrap + visual update
// ---------------------------------------------------------------------------

/datum/component/chain/proc/on_end_moved(atom/movable/mover, turf/old_loc)
	SIGNAL_HANDLER
	if(QDELETED(anchor) || QDELETED(parent))
		snap()
		return
	update_path_after_move(mover, old_loc)
	rebuild_all_nodes()
	update_slowdown()

/datum/component/chain/proc/on_end_deleted(datum/source)
	SIGNAL_HANDLER
	snap()

// ---------------------------------------------------------------------------
// Carrier proxy — items picked up by a mob
// ---------------------------------------------------------------------------

/**
 * Fired on COMSIG_ITEM_PICKUP when an item endpoint is picked up by a mob.
 * We begin proxying the carrier's PRE_MOVE/MOVED signals through to the endpoint logic
 * so that walking while holding a chained item still enforces chain constraints.
 */
/datum/component/chain/proc/on_end_picked_up(atom/movable/item, mob/user)
	SIGNAL_HANDLER
	if(QDELETED(user))
		return
	var/is_parent_end = (item == parent)
	var/mob/carrier = is_parent_end ? parent_carrier : anchor_carrier
	// Unregister old carrier if it changed (e.g. trading hands).
	if(carrier && carrier != user && !QDELETED(carrier))
		UnregisterSignal(carrier, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
	if(is_parent_end)
		parent_carrier = user
	else
		anchor_carrier = user
	// Don't double-register if the carrier is already a direct endpoint (mob with a component).
	if(user == anchor || user == parent)
		return
	RegisterSignal(user, COMSIG_MOVABLE_PRE_MOVE, PROC_REF(on_carrier_pre_move))
	RegisterSignal(user, COMSIG_MOVABLE_MOVED, PROC_REF(on_carrier_moved))

/**
 * Fired on COMSIG_ITEM_DROPPED when an item endpoint is put down.
 * Unregisters carrier proxy signals.
 */
/datum/component/chain/proc/on_end_dropped(atom/movable/item, mob/user)
	SIGNAL_HANDLER
	var/is_parent_end = (item == parent)
	if(!QDELETED(user) && user != anchor && user != parent)
		UnregisterSignal(user, list(COMSIG_MOVABLE_PRE_MOVE, COMSIG_MOVABLE_MOVED))
	if(is_parent_end)
		parent_carrier = null
	else
		anchor_carrier = null

/**
 * Proxy for COMSIG_MOVABLE_PRE_MOVE on a carrier mob.
 * Routes the move-enforcement logic to whichever endpoint the carrier is holding.
 */
/datum/component/chain/proc/on_carrier_pre_move(mob/carrier, atom/entering_loc)
	SIGNAL_HANDLER
	if(QDELETED(src))
		return
	var/atom/movable/carried = (carrier == parent_carrier) ? parent : anchor
	if(QDELETED(carried))
		return
	return on_end_pre_move(carried, entering_loc)

/**
 * Proxy for COMSIG_MOVABLE_MOVED on a carrier mob.
 * Routes the wrap/visual-update logic to whichever endpoint the carrier is holding.
 */
/datum/component/chain/proc/on_carrier_moved(mob/carrier, turf/old_loc)
	SIGNAL_HANDLER
	if(QDELETED(src))
		return
	var/atom/movable/carried = (carrier == parent_carrier) ? parent : anchor
	if(QDELETED(carried))
		return
	on_end_moved(carried, old_loc)

// ---------------------------------------------------------------------------
// Visual node management
// ---------------------------------------------------------------------------

/**
 * Spawns chain_node effect objects for the current full path.
 */
/datum/component/chain/proc/spawn_all_nodes()
	despawn_all_nodes()
	var/list/full_path = get_visual_path()
	var/n = length(full_path)
	if(n < 2)
		return
	for(var/i in 1 to n)
		var/turf/T = full_path[i]
		var/in_d = (i > 1) ? get_dir(full_path[i - 1], T) : NONE
		var/out_d = (i < n) ? get_dir(T, full_path[i + 1]) : NONE
		var/obj/effect/chain_node/node = new(T)
		node.set_dirs(in_d, out_d)
		node_effects[T] = node
	update_slack_nodes()

/**
 * Destroys all existing chain_node effect objects, including slack nodes.
 */
/datum/component/chain/proc/despawn_all_nodes()
	for(var/turf/T as anything in node_effects)
		var/obj/effect/chain_node/node = node_effects[T]
		if(!QDELETED(node))
			qdel(node)
	node_effects = list()
	if(slack_effects)
		for(var/obj/effect/chain_node/node as anything in slack_effects)
			if(!QDELETED(node))
				qdel(node)
		slack_effects = list()

/**
 * Rebuilds all visual node effects to match the current path.
 * Called after any wrap/unwrap change.
 * For performance, only updates icon_state on nodes whose direction pair changed.
 */
/datum/component/chain/proc/rebuild_all_nodes()
	var/list/full_path = get_visual_path()
	var/n = length(full_path)
	var/list/new_map = list()

	for(var/i in 1 to n)
		var/turf/T = full_path[i]
		var/in_d = (i > 1) ? get_dir(full_path[i - 1], T) : NONE
		var/out_d = (i < n) ? get_dir(T, full_path[i + 1]) : NONE
		var/obj/effect/chain_node/node = node_effects[T]
		if(QDELETED(node))
			node = new /obj/effect/chain_node(T)
		node.set_dirs(in_d, out_d) // no-op if dirs unchanged
		new_map[T] = node

	// Despawn nodes for turfs no longer in the path
	for(var/turf/T as anything in node_effects)
		if(!new_map[T])
			var/obj/effect/chain_node/old_node = node_effects[T]
			if(!QDELETED(old_node))
				qdel(old_node)

	node_effects = new_map
	update_slack_nodes()

// ---------------------------------------------------------------------------
// Snap / break
// ---------------------------------------------------------------------------

/**
 * Breaks the chain. Fires COMSIG_MOVABLE_CHAIN_SNAPPED on both ends,
 * drops the chain item if one exists, and deletes this component.
 */
/datum/component/chain/proc/snap(datum/source)
	if(!QDELETED(parent))
		SEND_SIGNAL(parent, COMSIG_MOVABLE_CHAIN_SNAPPED, src)
	if(!QDELETED(anchor))
		SEND_SIGNAL(anchor, COMSIG_MOVABLE_CHAIN_SNAPPED, src)

	// Drop the physical chain item near parent if it exists
	if(chain_item_ref)
		var/obj/item/chain/item = chain_item_ref.resolve()
		if(!QDELETED(item))
			var/turf/drop_loc = get_turf(parent)
			if(drop_loc)
				item.forceMove(drop_loc)
	chain_item_ref = null

	qdel(src)

// ---------------------------------------------------------------------------
// Slack node management
// ---------------------------------------------------------------------------

/**
 * Synchronises the slack node pool to match the current unused chain length.
 * Slack nodes are stacked on the parent endpoint's turf and use CHAIN_STATE_SLACK
 * to visually indicate how much chain is still "coiled" at the endpoint.
 * Count = max_length - total_path_length.  Clamped to [0, max_length].
 */
/datum/component/chain/proc/update_slack_nodes()
	var/slack = max(0, max_length - total_path_length)
	// Shrink the pool if we now have more slack nodes than needed.
	while(length(slack_effects) > slack)
		var/obj/effect/chain_node/excess = slack_effects[length(slack_effects)]
		slack_effects.len--
		if(!QDELETED(excess))
			qdel(excess)
	// Grow the pool if we need more slack nodes.
	var/turf/parent_turf = get_turf(parent)
	if(!parent_turf)
		return
	while(length(slack_effects) < slack)
		var/obj/effect/chain_node/node = new /obj/effect/chain_node(parent_turf)
		node.is_slack = TRUE
		node.icon_state = CHAIN_STATE_SLACK
		slack_effects += node

// ---------------------------------------------------------------------------
// Movespeed management
// ---------------------------------------------------------------------------

/**
 * Updates the multiplicative_slowdown on both mob-endpoint speed modifiers to
 * reflect the current taut ratio.  Fully slack = no slowdown; fully taut = CHAIN_MAX_SLOWDOWN.
 */
/datum/component/chain/proc/update_slowdown()
	if(!parent_speed_mod && !anchor_speed_mod)
		return
	var/taut_ratio = (max_length > 0) ? clamp((total_path_length - (max_length - 1)) / max_length, 0, 1) : 1
	var/slowdown = taut_ratio * CHAIN_MAX_SLOWDOWN
	if(parent_speed_mod)
		parent_speed_mod.multiplicative_slowdown = slowdown
		if(!QDELETED(parent) && ismob(parent))
			var/mob/parent_mob = parent
			parent_mob.update_movespeed()
	if(anchor_speed_mod)
		anchor_speed_mod.multiplicative_slowdown = slowdown
		if(!QDELETED(anchor) && ismob(anchor))
			var/mob/anchor_mob = anchor
			anchor_mob.update_movespeed()
