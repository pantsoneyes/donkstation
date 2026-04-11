/datum/element/invisible_ink

/datum/element/invisible_ink/Attach(datum/target)
	. = ..()
	if(!isatom(target))
		return ELEMENT_INCOMPATIBLE
	//target.add_filter("invisible_ink", 2, alpha_mask_filter(render_source = scanline.render_target))

/datum/element/invisible_ink/Detach(datum/source)
	//target.remove_filter("invisible_ink")
	return ..()
