/**
 * Chain link visual effect.
 *
 * Lightweight effect object placed on every tile the chain passes through.
 * Managed entirely by /datum/chain - do not spawn these manually.
 *
 * Icon states expected in chain.dmi:
 *   link_NS    - straight, north-south
 *   link_EW    - straight, east-west
 *   link_NE    - corner, north + east
 *   link_NW    - corner, north + west
 *   link_SE    - corner, south + east
 *   link_SW    - corner, south + west
 *   link_end   - endpoint cap (directional via dir)
 *
 * Until a dedicated chain.dmi is added, we fall back to the beam icon so the
 * code compiles and unit-tests pass.
 */
/obj/effect/chain_link
	name = "chain"
	desc = "A length of chain."
	icon = 'icons/hud/chain.dmi'
	icon_state = "link_end"
	layer = ABOVE_MOB_LAYER
	pass_flags = PASSTABLE | PASSGRILLE | PASSMOB
	anchored = TRUE
	/// The currently displayed icon state; cached to avoid unnecessary appearance updates
	var/current_state = ""

/**
 * Set this link's icon state and direction.
 * Pass is_end = TRUE for the terminal link at each endpoint.
 * The dir_flags argument is the BYOND direction bitfield (NORTH/SOUTH/EAST/WEST or
 * combinations for corners).
 */
/obj/effect/chain_link/proc/set_link_appearance(dir_flags, is_end = FALSE)
	var/new_state
	if(is_end)
		new_state = "link_end"
	else
		switch(dir_flags)
			if(NORTH|SOUTH)
				new_state = "link_NS"
			if(EAST|WEST)
				new_state = "link_EW"
			if(NORTH|EAST)
				new_state = "link_NE"
			if(NORTH|WEST)
				new_state = "link_NW"
			if(SOUTH|EAST)
				new_state = "link_SE"
			if(SOUTH|WEST)
				new_state = "link_SW"
			else
				new_state = "link_NS"  // fallback

	if(dir_flags && dir != dir_flags)
		setDir(dir_flags)
	if(new_state != current_state)
		current_state = new_state
		icon_state = new_state

/// Cleanup - chain datum calls qdel(), nothing else needed
/obj/effect/chain_link/Initialize(mapload)
	. = ..()
	ADD_TRAIT(src, TRAIT_BLOCKS_DOOR_CLOSE, TRAIT_GENERIC)

/obj/effect/chain_link/Destroy()
	return ..()
