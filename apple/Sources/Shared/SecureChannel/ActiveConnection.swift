/// Installs a new connection while synchronously retiring the old one first.
/// Keeping this tiny operation shared prevents Pilot and Copilot from drifting
/// back to the repeated-connect behavior that orphaned signaling/socket tasks.
func replaceActiveConnection<Connection: AnyObject>(
    _ active: inout Connection?,
    with replacement: Connection,
    disconnect: (Connection) -> Void
) {
    if let active { disconnect(active) }
    active = replacement
}
