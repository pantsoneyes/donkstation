/**
 * Chain datum.
 *
 * A standalone datum (not a component) that physically links two atom/movables.
 * It restricts movement, wraps around walls, pulls lighter endpoints, handles
 * throw behaviour, and renders chain-link visuals.
 *
 * Usage:
 *   var/datum/chain/C = new(endpoint_a, endpoint_b, max_length, break_force, restitution)
 *   ...
 *   qdel(C)  // detaches cleanly
 */
/datum/chain
	/// First chained endpoint
	var/atom/movable/endpoint_a
	/// Second chained endpoint
	var/atom/movable/endpoint_b
	/// Tile-path datum tracking wall-wrap waypoints
	var/datum/chain_path/path
	/// Maximum path length in tiles before the chain goes taut
	var/max_length = CHAIN_MAX_LENGTH_DEFAULT
	/// Throw-force required to break the chain outright
	var/break_force = CHAIN_BREAK_FORCE_DEFAULT
	/// Fraction of throw velocity reflected back on bounce (0-1)
	var/restitution = CHAIN_RESTITUTION_DEFAULT
	/// Whether the chain is currently taut
	var/is_taut = FALSE
	/// List of /obj/effect/chain_link visuals currently spawned
	var/list/links
	/// Guards against re-entrant redraw calls
	var/redrawing = FALSE
	/// Guards against re-entrant pull calls
	var/pulling = FALSE

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/datum/chain/New(
	atom/movable/a,
	atom/movable/b,
	max_length = CHAIN_MAX_LENGTH_DEFAULT,
	break_force = CHAIN_BREAK_FORCE_DEFAULT,
	restitution = CHAIN_RESTITUTION_DEFAULT,
)
	src.endpoint_a = a
	src.endpoint_b = b
	src.max_length = max_length
	src.break_force = break_force
	src.restitution = restitution

	links = list()
	path = new /datum/chain_path(get_turf(a), get_turf(b))

	_register_endpoint(a)
	_register_endpoint(b)

	SEND_SIGNAL(a, COMSIG_CHAIN_ATTACHED, src)
	SEND_SIGNAL(b, COMSIG_CHAIN_ATTACHED, src)

	// Trigger initial visual
	redraw_links()

/datum/chain/Destroy()
	SEND_SIGNAL(endpoint_a, COMSIG_CHAIN_BREAK, src)
	SEND_SIGNAL(endpoint_b, COMSIG_CHAIN_BREAK, src)

	if(endpoint_a)
		_unregister_endpoint(endpoint_a)
		SEND_SIGNAL(endpoint_a, COMSIG_CHAIN_DETACHED, src)
	if(endpoint_b)
		_unregister_endpoint(endpoint_b)
		SEND_SIGNAL(endpoint_b, COMSIG_CHAIN_DETACHED, src)

	endpoint_a = null
	endpoint_b = null

	_clear_links()
	qdel(path)
	path = null

	return ..()

// ---------------------------------------------------------------------------
// Signal registration helpers
// ---------------------------------------------------------------------------

/datum/chain/proc/_register_endpoint(atom/movable/ep)
	RegisterSignal(ep, COMSIG_MOVABLE_PRE_MOVE, PROC_REF(on_endpoint_pre_move))
	RegisterSignal(ep, COMSIG_MOVABLE_MOVED, PROC_REF(on_endpoint_moved))
	RegisterSignal(ep, COMSIG_MOVABLE_PRE_THROW, PROC_REF(on_endpoint_pre_throw))
	RegisterSignal(ep, COMSIG_MOVABLE_THROW_LANDED, PROC_REF(on_endpoint_throw_landed))
	RegisterSignal(ep, COMSIG_MOVABLE_Z_CHANGED, PROC_REF(on_endpoint_z_changed))
	RegisterSignal(ep, COMSIG_QDELETING, PROC_REF(on_endpoint_deleted))

	// Also track the endpoint when it lives inside containers via connect_containers.
	// We only use this for MOVED so the path stays current even in bags/lockers.
	var/list/container_connections = list(
		COMSIG_MOVABLE_MOVED = PROC_REF(on_endpoint_moved),
	)
	ep.AddComponent(/datum/component/connect_containers, ep, container_connections)

/datum/chain/proc/_unregister_endpoint(atom/movable/ep)
	if(QDELETED(ep))
		return
	UnregisterSignal(ep, list(
		COMSIG_MOVABLE_PRE_MOVE,
		COMSIG_MOVABLE_MOVED,
		COMSIG_MOVABLE_PRE_THROW,
		COMSIG_MOVABLE_THROW_LANDED,
		COMSIG_MOVABLE_Z_CHANGED,
		COMSIG_QDELETING,
	))

// ---------------------------------------------------------------------------
// Signal handlers
// ---------------------------------------------------------------------------

/**
 * Fires on an endpoint before it moves.
 * Blocks the move when the chain would go taut, unless we can pull the other
 * endpoint.
 */
/datum/chain/proc/on_endpoint_pre_move(atom/movable/source, atom/new_location)
	SIGNAL_HANDLER

	if(QDELETED(src))
		return NONE

	var/turf/proposed = get_turf(new_location)
	if(!proposed)
		return NONE

	// Compute tentative path length for the proposed position
	var/tentative
	if(source == endpoint_a)
		tentative = path.tentative_length_if_a_moves(proposed)
	else
		tentative = path.tentative_length_if_b_moves(proposed)

	if(tentative <= max_length)
		return NONE

	// Chain would go taut - check if we can pull the other end
	var/atom/movable/other = (source == endpoint_a) ? endpoint_b : endpoint_a
	if(!QDELETED(other) && _can_pull(source, other))
		// Verify the pull step is actually passable - a door or wall may block it
		var/turf/other_turf = get_turf(other)
		var/pull_dir = get_dir(other_turf, proposed)
		if(pull_dir)
			var/turf/pull_step = get_step(other_turf, pull_dir)
			if(pull_step && path && path.is_chain_passable(pull_step))
				return NONE  // Pull is feasible; post-move handler will pull

	// Block the move
	if(ismob(source))
		source.balloon_alert(source, "chain taut!")
	return COMPONENT_MOVABLE_BLOCK_PRE_MOVE

/**
 * Fires after an endpoint has moved.
 * Updates the path, checks tautness, pulls the other endpoint if needed, and
 * schedules a visual redraw.
 */
/datum/chain/proc/on_endpoint_moved(atom/movable/source, atom/old_loc, dir, forced, list/old_locs, momentum_change)
	SIGNAL_HANDLER

	if(QDELETED(src))
		return

	var/turf/new_turf = get_turf(source)
	if(!new_turf)
		return

	// Update path
	var/over_wrapped
	if(source == endpoint_a)
		over_wrapped = path.recalculate_from_a(new_turf)
	else
		over_wrapped = path.recalculate_from_b(new_turf)

	if(over_wrapped)
		qdel(src)  // Chain is hopelessly tangled; break it
		return

	_update_taut_state()

	// Pull other endpoint if taut and we outmass it
	if(is_taut && !pulling)
		var/atom/movable/other = (source == endpoint_a) ? endpoint_b : endpoint_a
		if(!QDELETED(other) && _can_pull(source, other))
			INVOKE_ASYNC(src, PROC_REF(_do_pull), source, other)

	redraw_links()

/**
 * Fires when an endpoint is thrown.
 * Clamps the throw range to available slack, or breaks the chain if the throw
 * force exceeds break_force.  Below break_force a bounce is applied instead.
 */
/datum/chain/proc/on_endpoint_pre_throw(atom/movable/source, list/throw_args)
	SIGNAL_HANDLER

	if(QDELETED(src))
		return NONE

	var/used = path.get_used_length()
	var/slack = max(0, max_length - used)

	var/throw_range = throw_args["range"] || 7
	if(slack >= throw_range)
		return NONE  // Plenty of room; throw proceeds normally

	var/force = throw_args["force"] || MOVE_FORCE_STRONG
	if(force >= break_force)
		// Chain breaks; let the throw happen unimpeded
		qdel(src)
		return NONE

	// Not enough force to break; cancel and schedule a bounce
	INVOKE_ASYNC(src, PROC_REF(_do_bounce), source, throw_args)
	return COMPONENT_CANCEL_THROW

/**
 * Fires when a thrown endpoint lands.
 * Not currently used but available for future effects (sparks, sounds).
 */
/datum/chain/proc/on_endpoint_throw_landed(atom/movable/source, datum/thrownthing/thrown)
	SIGNAL_HANDLER
	// Visual/audio cue could go here

/**
 * Fires when an endpoint changes Z level.
 * A chain cannot span Z levels - break it.
 */
/datum/chain/proc/on_endpoint_z_changed(atom/movable/source, turf/old_turf, turf/new_turf)
	SIGNAL_HANDLER
	qdel(src)

/**
 * Fires when an endpoint is about to be deleted.
 * Break the chain.
 */
/datum/chain/proc/on_endpoint_deleted(atom/movable/source)
	SIGNAL_HANDLER
	qdel(src)

// ---------------------------------------------------------------------------
// Internal logic
// ---------------------------------------------------------------------------

/// Returns TRUE if puller can drag pulled (mass comparison + anchored check)
/datum/chain/proc/_can_pull(atom/movable/puller, atom/movable/pulled)
	if(pulled.anchored)
		return FALSE
	return puller.mass >= pulled.mass

/// Recompute is_taut from current path length and emit taut/slack signals
/datum/chain/proc/_update_taut_state()
	var/used = path.get_used_length()
	var/now_taut = (used >= max_length)
	if(now_taut == is_taut)
		return
	is_taut = now_taut
	if(is_taut)
		SEND_SIGNAL(endpoint_a, COMSIG_CHAIN_TAUT, src)
		SEND_SIGNAL(endpoint_b, COMSIG_CHAIN_TAUT, src)
	else
		SEND_SIGNAL(endpoint_a, COMSIG_CHAIN_SLACK, src)
		SEND_SIGNAL(endpoint_b, COMSIG_CHAIN_SLACK, src)

/**
 * Asynchronously steps the lighter endpoint one tile toward the heavier one.
 * Called after a move that left the chain taut.
 */
/datum/chain/proc/_do_pull(atom/movable/puller, atom/movable/pulled)
	set waitfor = FALSE

	if(QDELETED(src) || QDELETED(puller) || QDELETED(pulled))
		return
	pulling = TRUE

	var/turf/puller_turf = get_turf(puller)
	var/turf/pulled_turf = get_turf(pulled)
	if(!puller_turf || !pulled_turf)
		pulling = FALSE
		return

	var/move_dir = get_dir(pulled_turf, puller_turf)
	if(!move_dir)
		pulling = FALSE
		return

	pulled.Move(get_step(pulled_turf, move_dir), move_dir)
	pulling = FALSE

/**
 * Asynchronously applies a restitution bounce when a throw was cancelled by
 * the chain going taut.  Throws the endpoint back toward the other endpoint.
 */
/datum/chain/proc/_do_bounce(atom/movable/source, list/throw_args)
	set waitfor = FALSE

	if(QDELETED(src) || QDELETED(source))
		return

	var/atom/movable/other = (source == endpoint_a) ? endpoint_b : endpoint_a
	if(QDELETED(other))
		return

	var/turf/source_turf = get_turf(source)
	var/turf/other_turf = get_turf(other)
	if(!source_turf || !other_turf)
		return

	// Direction from source back toward the other endpoint
	var/bounce_dir = get_dir(source_turf, other_turf)
	if(!bounce_dir)
		return

	var/original_speed = throw_args["speed"] || 2
	var/original_range = throw_args["range"] || 7
	var/bounce_range = max(1, round(original_range * restitution))
	var/bounce_speed = max(1, round(original_speed * restitution))
	var/atom/thrower = throw_args["thrower"]

	var/turf/bounce_target = get_step(source_turf, bounce_dir)
	if(!bounce_target)
		return

	source.throw_at(bounce_target, bounce_range, bounce_speed, thrower, spin = FALSE, force = MOVE_FORCE_WEAK)

// ---------------------------------------------------------------------------
// Visuals
// ---------------------------------------------------------------------------

/// Schedule a non-blocking redraw of all chain link objects
/datum/chain/proc/redraw_links()
	set waitfor = FALSE

	if(redrawing || QDELETED(src))
		return
	redrawing = TRUE

	_clear_links()

	if(!endpoint_a || !endpoint_b || QDELETED(endpoint_a) || QDELETED(endpoint_b))
		redrawing = FALSE
		return

	// Build ordered list: endpoint_a_turf, waypoints..., endpoint_b_turf
	var/list/segments = list()
	var/turf/a_turf = get_turf(endpoint_a)
	var/turf/b_turf = get_turf(endpoint_b)
	if(!a_turf || !b_turf || a_turf.z != b_turf.z)
		redrawing = FALSE
		return

	segments += a_turf
	for(var/turf/wp as anything in path.waypoints)
		segments += wp
	segments += b_turf

	// Flatten into per-tile list via get_line between consecutive nodes
	var/list/all_turfs = list()
	for(var/i in 1 to length(segments) - 1)
		var/list/segment_line = get_line(segments[i], segments[i + 1])
		for(var/turf/T as anything in segment_line)
			if(!(T in all_turfs))
				all_turfs += T

	// Spawn / position link objects
	for(var/i in 1 to all_turfs.len)
		var/turf/T = all_turfs[i]
		var/obj/effect/chain_link/link = new(T)
		links += link

		// Determine direction for icon orientation
		var/link_dir = SOUTH
		if(i < all_turfs.len)
			link_dir = get_dir(T, all_turfs[i + 1])
		else if(i > 1)
			link_dir = get_dir(all_turfs[i - 1], T)

		// Detect corners
		if(i > 1 && i < all_turfs.len)
			var/dir_in  = get_dir(all_turfs[i - 1], T)
			var/dir_out = get_dir(T, all_turfs[i + 1])
			if(dir_in != dir_out)
				link.set_link_appearance(REVERSE_DIR(dir_in) | dir_out)
			else
				link.set_link_appearance(dir_in | dir_out)
		else if(i == 1)
			link.set_link_appearance(link_dir, is_end = TRUE)
		else
			link.set_link_appearance(link_dir, is_end = TRUE)

	redrawing = FALSE

/// Delete all visual link objects
/datum/chain/proc/_clear_links()
	for(var/obj/effect/chain_link/link as anything in links)
		if(!QDELETED(link))
			qdel(link)
	links.Cut()
