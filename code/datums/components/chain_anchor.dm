/**
 * Chain anchor component.
 *
 * Attaches to any /atom/movable and marks it as a static anchor point for
 * chain endpoints by setting mass to CHAIN_STATIC_MASS.  Static anchors
 * cannot be pulled by a chain no matter what pulls against them.
 *
 * Applied automatically to /obj/structure/wall_hook; can also be added
 * programmatically to any fixed structure.
 */
/datum/component/chain_anchor
	/// Original mass before anchoring, restored on Destroy()
	var/original_mass

/datum/component/chain_anchor/Initialize()
	. = ..()
	if(!ismovable(parent))
		return COMPONENT_INCOMPATIBLE
	var/atom/movable/M = parent
	original_mass = M.mass
	M.mass = CHAIN_STATIC_MASS

/datum/component/chain_anchor/Destroy()
	if(!QDELETED(parent))
		var/atom/movable/M = parent
		M.mass = original_mass
	return ..()
