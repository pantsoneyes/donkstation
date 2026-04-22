/**
 * Wall hook structure.
 *
 * A small bracket that can be bolted to any wall tile to provide a static
 * anchor point for chain endpoints.  Installed with a screwdriver and one
 * metal rod; removed the same way.
 *
 * While present the hook has CHAIN_STATIC_MASS (via chain_anchor component)
 * and move_resist = INFINITY so it can never be pulled or moved by a chain.
 */
/obj/structure/wall_hook
	name = "wall hook"
	desc = "A sturdy metal bracket bolted to the wall. You could attach a chain to it."
	icon = 'icons/obj/structures.dmi'
	icon_state = "railing"  // placeholder sprite until a dedicated one is made
	density = FALSE
	anchored = TRUE
	move_resist = INFINITY
	layer = OBJ_LAYER
	/// Typepath of the item dropped when the hook is removed
	var/drop_type = /obj/item/stack/rods

/obj/structure/wall_hook/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/chain_anchor)

/obj/structure/wall_hook/Destroy()
	return ..()

/obj/structure/wall_hook/attackby(obj/item/I, mob/user, params)
	if(I.tool_behaviour == TOOL_SCREWDRIVER)
		user.visible_message(
			span_notice("[user] unscrews [src] from the wall."),
			span_notice("You unscrew [src] from the wall."),
		)
		var/obj/item/stack/drop = new drop_type(get_turf(src))
		drop.amount = 1
		qdel(src)
		return
	return ..()

/// Convenience place-target: attackby a wall with screwdriver + rod to install
/obj/item/stack/rods/proc/place_wall_hook(turf/target, mob/user)
	if(!isturf(target))
		return FALSE
	if(use(1))
		new /obj/structure/wall_hook(target)
		user.balloon_alert(user, "hook installed")
		return TRUE
	return FALSE
