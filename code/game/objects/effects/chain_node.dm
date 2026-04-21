/**
 * A single tile-sized visual effect placed on each turf that a chain passes through.
 * Icon states represent straight (NS/EW) and corner (NE/NW/SE/SW) segments, plus endpoint stubs.
 * Only updates its icon_state when the entering or exiting direction actually changes,
 * keeping appearance updates sparse for performance.
 *
 * Icon file: 'icons/obj/chain.dmi'
 * Required icon states: chain_ns, chain_ew, chain_ne, chain_nw, chain_se, chain_sw,
 *                       chain_end_n, chain_end_s, chain_end_e, chain_end_w
 */
/obj/effect/chain_node
	name = "chain"
	desc = "A length of chain."
	icon = 'icons/obj/chain.dmi'
	icon_state = CHAIN_STATE_NS
	layer = OBJ_LAYER + 0.1
	mouse_opacity = MOUSE_OPACITY_ICON
	anchored = TRUE
	/// Direction the chain arrives from (direction of the previous node/endpoint toward this tile)
	var/in_dir = NONE
	/// Direction the chain exits toward (direction of the next node/endpoint from this tile)
	var/out_dir = NONE
	/// If TRUE, this node is a slack link piled at the parent's turf rather than a path segment.
	var/is_slack = FALSE

/**
 * Update the entry/exit directions of this node.
 * Only calls icon_state assignment when the pair actually changes — this keeps
 * icon updates sparse when only the ends of the chain are moving.
 * Arguments:
 * - new_in: incoming direction (from the previous node toward this tile)
 * - new_out: outgoing direction (from this tile toward the next node)
 */
/obj/effect/chain_node/proc/set_dirs(new_in, new_out)
	if(new_in == in_dir && new_out == out_dir)
		return
	in_dir = new_in
	out_dir = new_out
	// Combine both directions into a bitmask and map to the correct icon state
	icon_state = CHAIN_DIR_TO_STATE(in_dir | out_dir)
