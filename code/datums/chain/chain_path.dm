/**
 * Chain path datum.
 *
 * Tracks the tile-by-tile route between two chain endpoints, wrapping around
 * walls by inserting/removing corner waypoints.  Call recalculate_from_a() or
 * recalculate_from_b() after an endpoint moves.
 *
 * Path order: endpoint_a_turf -> waypoints[1..n] -> endpoint_b_turf
 */
/datum/chain_path
	/// Current turf of endpoint A
	var/turf/endpoint_a_turf
	/// Current turf of endpoint B
	var/turf/endpoint_b_turf
	/// Ordered list of corner-waypoint turfs between the two endpoints
	var/list/waypoints

/datum/chain_path/New(turf/a, turf/b)
	waypoints = list()
	endpoint_a_turf = a
	endpoint_b_turf = b

/datum/chain_path/Destroy()
	waypoints = null
	endpoint_a_turf = null
	endpoint_b_turf = null
	return ..()

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Recalculate path after endpoint A moves.
 * Returns TRUE if the chain has become hopelessly wrapped (too many waypoints),
 * which the caller should treat as a break condition.
 */
/datum/chain_path/proc/recalculate_from_a(turf/new_a)
	var/turf/old_a = endpoint_a_turf
	endpoint_a_turf = new_a
	return _recalculate_end(new_a, old_a, TRUE)

/**
 * Recalculate path after endpoint B moves.
 * Returns TRUE if the chain has become hopelessly wrapped.
 */
/datum/chain_path/proc/recalculate_from_b(turf/new_b)
	var/turf/old_b = endpoint_b_turf
	endpoint_b_turf = new_b
	return _recalculate_end(new_b, old_b, FALSE)

/// Sum of distances through the full ordered path (endpoint_a -> waypoints -> endpoint_b)
/datum/chain_path/proc/get_used_length()
	. = 0
	if(!endpoint_a_turf || !endpoint_b_turf)
		return 0
	var/turf/prev = endpoint_a_turf
	for(var/turf/wp as anything in waypoints)
		. += get_dist(prev, wp)
		prev = wp
	. += get_dist(prev, endpoint_b_turf)

/**
 * Lightweight estimate of path length if A were to move to proposed_turf.
 * Does NOT mutate state.  Accounts for a new bend that would be needed if
 * proposed has no LOS to the first waypoint (or B).
 */
/datum/chain_path/proc/tentative_length_if_a_moves(turf/proposed)
	if(!proposed || !endpoint_b_turf)
		return 0
	. = 0
	var/turf/first_node = waypoints.len > 0 ? waypoints[1] : endpoint_b_turf
	var/turf/prev = proposed
	// If proposed can't see the first node the chain will have to bend at the
	// current A position - add that extra segment up front.
	if(first_node && !los_between(proposed, first_node))
		. += get_dist(proposed, endpoint_a_turf)
		prev = endpoint_a_turf
	for(var/turf/wp as anything in waypoints)
		. += get_dist(prev, wp)
		prev = wp
	. += get_dist(prev, endpoint_b_turf)

/**
 * Lightweight estimate if B were to move to proposed_turf.
 * Accounts for a new bend that would be needed if the last node has no LOS to
 * proposed.
 */
/datum/chain_path/proc/tentative_length_if_b_moves(turf/proposed)
	if(!proposed || !endpoint_a_turf)
		return 0
	. = 0
	var/turf/prev = endpoint_a_turf
	for(var/turf/wp as anything in waypoints)
		. += get_dist(prev, wp)
		prev = wp
	// If prev (last waypoint or A) can't see proposed, chain bends at current B.
	if(!los_between(prev, proposed))
		. += get_dist(prev, endpoint_b_turf)
		prev = endpoint_b_turf
	. += get_dist(prev, proposed)

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Core recalculation for one end.
 * is_a_end TRUE -> recalculating from A's side (waypoints[1] is the adjacent corner).
 * is_a_end FALSE -> recalculating from B's side (waypoints[len] is adjacent).
 * old_end is the endpoint's previous turf - used as the physical bend point when
 * the new position has no LOS to the next node.
 */
/datum/chain_path/proc/_recalculate_end(turf/new_end, turf/old_end, is_a_end)
	if(!new_end)
		return FALSE

	// --- Step 1: Try to remove unnecessary waypoints from this end ---
	// A waypoint can be removed when we have clear LOS to the one after it.
	while(waypoints.len > 0)
		var/turf/skip_target
		if(is_a_end)
			skip_target = (waypoints.len >= 2) ? waypoints[2] : endpoint_b_turf
		else
			skip_target = (waypoints.len >= 2) ? waypoints[waypoints.len - 1] : endpoint_a_turf
		if(skip_target && los_between(new_end, skip_target))
			if(is_a_end)
				waypoints.Cut(1, 2)
			else
				waypoints.Cut(waypoints.len, waypoints.len + 1)
		else
			break

	// --- Step 2: Check if we need to insert a new corner ---
	var/turf/first_target
	if(is_a_end)
		first_target = waypoints.len > 0 ? waypoints[1] : endpoint_b_turf
	else
		first_target = waypoints.len > 0 ? waypoints[waypoints.len] : endpoint_a_turf

	if(first_target && !los_between(new_end, first_target))
		// Physical rope model: the endpoint had to travel around an obstacle to reach
		// new_end, so old_end is where the rope physically wraps.  Use it as the
		// waypoint when it has clear LOS to the next node.  Fall back to geometric
		// corner-finding only if old_end itself is unusable.
		var/turf/corner = null
		if(old_end && old_end != new_end && old_end != first_target && los_between(old_end, first_target))
			corner = old_end
		else
			corner = find_wrap_corner(new_end, first_target)
		if(corner && corner != new_end)
			if(is_a_end)
				waypoints.Insert(1, corner)
			else
				waypoints += corner
		else
			// No valid corner found - geometry is impassable, break the chain
			return TRUE

	// --- Step 3: Safety check for waypoint overflow ---
	if(waypoints.len > CHAIN_MAX_WAYPOINTS)
		return TRUE
	return FALSE

/**
 * Walk get_line(from->target) and return the last passable turf before the first
 * blocker (i.e., the "corner" of the wall).
 */
/datum/chain_path/proc/find_wrap_corner(turf/from, turf/target)
	var/list/line = get_line(from, target)
	var/turf/last_passable = from
	for(var/turf/T as anything in line)
		if(!is_chain_passable(T))
			return last_passable
		last_passable = T
	return last_passable

/**
 * Returns TRUE if there is a clear (wall-free) line between a and b.
 * Checks all turfs in the line from index 2 onward (we stand on a itself).
 */
/datum/chain_path/proc/los_between(turf/a, turf/b)
	if(!a || !b)
		return FALSE
	if(a == b)
		return TRUE
	var/list/line = get_line(a, b)
	for(var/i in 2 to length(line))
		var/turf/T = line[i]
		if(!is_chain_passable(T))
			return FALSE
	return TRUE

/**
 * Returns FALSE if this turf (or a dense non-mob object on it) would block a
 * physical chain from passing.
 */
/datum/chain_path/proc/is_chain_passable(turf/T)
	if(T.density)
		return FALSE
	for(var/atom/obj in T.contents)
		if(obj.density && !ismob(obj))
			return FALSE
	return TRUE
