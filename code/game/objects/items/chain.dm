/**
 * A physical chain that players can use to link two atom/movables together.
 *
 * Usage:
 *   - Click a movable to set the first attachment point.
 *   - Click a second movable to fully deploy the chain between the two.
 *   - Click the first target again, or use in-hand, to cancel the pending attachment.
 *   - Use in-hand while deployed to detach and coil the chain.
 *
 * The chain constrains movement via /datum/component/chain (see chain.dm).
 */
/obj/item/chain
	name = "chain"
	desc = "A length of heavy chain. You could use it to link two objects together."
	icon = 'icons/obj/chain.dmi'
	icon_state = "chain"
	/// Maximum path length the deployed chain allows.
	var/max_length = CHAIN_LENGTH_DEFAULT
	/// Force required to break the deployed chain.
	var/break_force = CHAIN_BREAK_FORCE_DEFAULT
	/// The movable the first end is hooked onto, while we wait for the second target.
	var/atom/movable/first_end = null
	/// Weakref to the chain component once fully deployed, for later removal.
	var/datum/weakref/deployed_component_ref = null
	/// Weakref to a temporary preview chain component (first_end → holder) shown while awaiting second attachment.
	var/datum/weakref/preview_component_ref = null

// --- Interaction ---

/obj/item/chain/interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	if(!ismovable(interacting_with) || istype(interacting_with, /obj/item/chain))
		return NONE

	var/atom/movable/target = interacting_with

	// Already deployed — clicking something while a component is active does nothing here.
	if(deployed_component_ref)
		return NONE

	// No first end yet — attach to this target.
	if(isnull(first_end))
		if(QDELETED(target))
			return NONE
		first_end = target
		// Spawn a live preview chain from first_end to the holder so the chain is visible
		// and length-enforced while waiting for the second attachment point.
		var/datum/component/chain/P = target.AddComponent( \
			/datum/component/chain, \
			user, \
			max_length, \
			break_force, \
			name \
		)
		preview_component_ref = WEAKREF(P)
		user.balloon_alert(user, "you loop one end of the [name] around [target]")
		return ITEM_INTERACT_SUCCESS

	// First end is the same target — cancel.
	if(target == first_end)
		var/datum/component/chain/P = preview_component_ref?.resolve()
		if(!QDELETED(P))
			P.snap()
		preview_component_ref = null
		first_end = null
		user.balloon_alert(user, "you coil the [name] back up")
		return ITEM_INTERACT_SUCCESS

	// First end is already set and we clicked a different target — deploy!
	if(QDELETED(first_end))
		var/datum/component/chain/P = preview_component_ref?.resolve()
		if(!QDELETED(P))
			P.snap()
		preview_component_ref = null
		first_end = null
		user.balloon_alert(user, "the first anchor is gone, you coil the [name] back up")
		return ITEM_INTERACT_SUCCESS

	// Snap the preview before replacing it with the real deployed chain.
	var/datum/component/chain/P = preview_component_ref?.resolve()
	if(!QDELETED(P))
		P.snap()
	preview_component_ref = null

	var/atom/movable/saved_first_end = first_end
	first_end = null

	// Add the component on saved_first_end, pointing to target as the anchor.
	var/datum/component/chain/C = saved_first_end.AddComponent( \
		/datum/component/chain, \
		target, \
		max_length, \
		break_force, \
		name, \
		WEAKREF(src) \
	)
	if(QDELETED(C))
		// Component rejected (e.g. wall between endpoints).
		user.balloon_alert(user, "something is in the way!")
		first_end = saved_first_end
		return ITEM_INTERACT_SUCCESS
	deployed_component_ref = WEAKREF(C)

	// Move chain item out of user's hand — it is now "installed".
	user.temporarilyRemoveItemFromInventory(src)
	src.forceMove(get_turf(saved_first_end))
	src.invisibility = INVISIBILITY_MAXIMUM // hidden while deployed; snap() will restore it

	// Listen for the chain being snapped externally.
	RegisterSignal(saved_first_end, COMSIG_MOVABLE_CHAIN_SNAPPED, PROC_REF(on_chain_snapped))

	user.balloon_alert(user, "you loop the other end of the [name] around [target]")
	return ITEM_INTERACT_SUCCESS

/obj/item/chain/attack_self(mob/user)
	// Cancel pending first-end attachment.
	if(!isnull(first_end) && !deployed_component_ref)
		var/datum/component/chain/P = preview_component_ref?.resolve()
		if(!QDELETED(P))
			P.snap()
		preview_component_ref = null
		first_end = null
		user.balloon_alert(user, "you coil the [name] back up")
		return

	// Detach a deployed chain.
	if(deployed_component_ref)
		var/datum/component/chain/C = deployed_component_ref.resolve()
		if(!QDELETED(C))
			C.snap()
			// snap() fires COMSIG_MOVABLE_CHAIN_SNAPPED → on_chain_snapped() → restores item.
		return

/obj/item/chain/Destroy()
	// Snap preview if we were mid-attachment.
	if(preview_component_ref)
		var/datum/component/chain/P = preview_component_ref.resolve()
		if(!QDELETED(P))
			P.snap()
		preview_component_ref = null
	// If we're destroyed while deployed, snap the chain component too.
	if(deployed_component_ref)
		var/datum/component/chain/C = deployed_component_ref.resolve()
		if(!QDELETED(C))
			C.snap()
	deployed_component_ref = null
	first_end = null
	return ..()

// --- Signal handler ---

/**
 * Called when the deployed chain component fires COMSIG_MOVABLE_CHAIN_SNAPPED
 * (either from snap() or from an external break).
 * Restores the item to the world and unregisters the signal.
 */
/obj/item/chain/proc/on_chain_snapped(datum/source, datum/component/chain/component)
	SIGNAL_HANDLER
	deployed_component_ref = null
	invisibility = NONE
	if(first_end && !QDELETED(first_end))
		UnregisterSignal(first_end, COMSIG_MOVABLE_CHAIN_SNAPPED)
	first_end = null
	// The snap() proc in chain.dm already forceMoves us to get_turf(parent).
	// Nothing more needed here beyond cleaning up our state.

// =============================================================================
// Chain hook — a static anchor point that chains can be attached to.
// =============================================================================

/**
 * A fixed anchor ring bolted to a surface.  Provides an anchored atom/movable
 * target so players can chain movables to walls, floors, or pillars.
 * Remove it by attacking with a wrench.
 */
/obj/structure/chain_hook
	name = "chain hook"
	desc = "A heavy iron ring fixed to the surface. Chains can be attached to it."
	icon = 'icons/obj/chain.dmi'
	icon_state = "chain_hook"
	anchored = TRUE
	density = FALSE
	layer = BELOW_OBJ_LAYER

/obj/structure/chain_hook/attackby(obj/item/weapon, mob/user, params)
	if(istype(weapon, /obj/item/wrench))
		user.balloon_alert(user, "you unbolt the [name]")
		var/obj/item/chain_hook/dropped = new /obj/item/chain_hook(get_turf(src))
		dropped.add_fingerprint(user)
		qdel(src)
		return
	return ..()

/**
 * A handheld chain hook.  Click on a turf or wall to bolt it in place,
 * creating an /obj/structure/chain_hook at that location.
 */
/obj/item/chain_hook
	name = "chain hook"
	desc = "A heavy iron ring. Bolt it to a surface with a wrench, or click a location to place it."
	icon = 'icons/obj/chain.dmi'
	icon_state = "chain_hook"

/obj/item/chain_hook/interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	var/turf/target_turf = get_turf(interacting_with)
	if(!target_turf)
		return NONE
	user.balloon_alert(user, "you bolt the [name] to [interacting_with]")
	new /obj/structure/chain_hook(target_turf)
	qdel(src)
	return ITEM_INTERACT_SUCCESS
