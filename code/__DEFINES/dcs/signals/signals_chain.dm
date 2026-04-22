/// Fired on both endpoints when a chain becomes taut; return value unused
#define COMSIG_CHAIN_TAUT "chain_taut"
/// Fired on both endpoints when a taut chain becomes slack again; return value unused
#define COMSIG_CHAIN_SLACK "chain_slack"
/// Fired on both endpoints immediately before the chain datum is destroyed; return value unused
#define COMSIG_CHAIN_BREAK "chain_break"
/// Fired on an atom when a chain endpoint is first attached to it; (datum/chain/chain)
#define COMSIG_CHAIN_ATTACHED "chain_attached"
/// Fired on an atom when a chain endpoint is detached; (datum/chain/chain)
#define COMSIG_CHAIN_DETACHED "chain_detached"
