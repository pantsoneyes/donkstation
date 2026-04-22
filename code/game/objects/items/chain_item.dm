/**
 * Physical chain item.
 *
 * Two-step attachment:
 *   1. Click any valid atom/movable -> select as first endpoint (pending_endpoint_a)
 *   2. Click any other valid atom/movable -> create the datum/chain linking them
 *
 * Click self (Z-key) to cancel a pending attachment.
 *
 * Subtypes adjust default max_length and break_force.
 */
/obj/item/chain
	name = "chain"
	desc = "A heavy linked chain. Click something to attach one end, then click something else to attach the other."
	icon = 'icons/hud/chain.dmi'
	icon_state = "chain"  // placeholder; swap when dedicated sprite exists
	w_class = WEIGHT_CLASS_NORMAL
	force = 5
	throwforce = 8
	throw_speed = 2
	throw_range = 5

	/// Maximum tile-length of the chain created by this item
	var/max_length = CHAIN_MAX_LENGTH_DEFAULT
	/// Force required to break the created chain
	var/break_force = CHAIN_BREAK_FORCE_DEFAULT
	/// Restitution factor for the created chain
	var/restitution = CHAIN_RESTITUTION_DEFAULT

	/// First attachment target chosen by the user (nil if none selected yet)
	var/atom/movable/pending_endpoint_a = null
	/// Currently active chain datum, if any, created by this item
	var/datum/chain/active_chain = null

/obj/item/chain/Destroy()
	pending_endpoint_a = null
	// The chain datum owns its own lifecycle; we just drop our reference
	active_chain = null
	return ..()

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

/obj/item/chain/interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	if(SHOULD_SKIP_INTERACTION(interacting_with, src, user))
		return NONE

	if(!ismovable(interacting_with))
		user.balloon_alert(user, "can't attach to that!")
		return ITEM_INTERACT_BLOCKING

	var/atom/movable/movable_target = interacting_with

	// Step 1: select first endpoint
	if(!pending_endpoint_a)
		if(active_chain)
			user.balloon_alert(user, "chain already attached - detach first!")
			return ITEM_INTERACT_BLOCKING
		pending_endpoint_a = movable_target
		user.balloon_alert(user, "first end attached to [interacting_with.name] - click another target")
		return ITEM_INTERACT_SUCCESS

	// Step 2: select second endpoint and create chain
	if(movable_target == pending_endpoint_a)
		user.balloon_alert(user, "can't attach both ends to the same thing!")
		return ITEM_INTERACT_BLOCKING

	// Sanity: must be on the same Z level
	var/turf/a_turf = get_turf(pending_endpoint_a)
	var/turf/b_turf = get_turf(movable_target)
	if(!a_turf || !b_turf || a_turf.z != b_turf.z)
		user.balloon_alert(user, "endpoints must be on the same level!")
		pending_endpoint_a = null
		return ITEM_INTERACT_BLOCKING

	// Sanity: must be within max_length at the moment of attachment
	if(get_dist(a_turf, b_turf) > max_length)
		user.balloon_alert(user, "too far apart!")
		pending_endpoint_a = null
		return ITEM_INTERACT_BLOCKING

	active_chain = new /datum/chain(pending_endpoint_a, movable_target, max_length, break_force, restitution)
	// Clean up if chain self-destructed immediately (e.g. endpoints on different Z)
	if(QDELETED(active_chain))
		active_chain = null
		pending_endpoint_a = null
		user.balloon_alert(user, "chain failed to attach!")
		return ITEM_INTERACT_BLOCKING

	RegisterSignal(active_chain, COMSIG_QDELETING, PROC_REF(on_chain_deleted))
	user.visible_message(
		span_notice("[user] attaches a chain between [pending_endpoint_a.name] and [movable_target.name]."),
		span_notice("You attach the chain between [pending_endpoint_a.name] and [movable_target.name]."),
	)
	pending_endpoint_a = null
	return ITEM_INTERACT_SUCCESS

/obj/item/chain/attack_self(mob/user)
	if(pending_endpoint_a)
		user.balloon_alert(user, "attachment cancelled")
		pending_endpoint_a = null
		return
	if(active_chain)
		user.balloon_alert(user, "chain detached")
		qdel(active_chain)
		active_chain = null
		return
	user.balloon_alert(user, "nothing to detach")

// ---------------------------------------------------------------------------
// Signal handlers
// ---------------------------------------------------------------------------

/obj/item/chain/proc/on_chain_deleted()
	SIGNAL_HANDLER
	active_chain = null

// ---------------------------------------------------------------------------
// Subtypes
// ---------------------------------------------------------------------------

/// Short chain - only 3 tiles long
/obj/item/chain/short
	name = "short chain"
	desc = "A short, heavy linked chain."
	max_length = 3

/// Heavy chain - requires tremendous force to break
/obj/item/chain/heavy
	name = "heavy chain"
	desc = "A thick, very heavy chain. It would take something truly catastrophic to break this."
	w_class = WEIGHT_CLASS_BULKY
	break_force = MOVE_FORCE_OVERPOWERING
