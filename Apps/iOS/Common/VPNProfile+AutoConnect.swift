import NetworkExtension

extension VPNProfile {
    func makeOnDemandRules() -> [NEOnDemandRule] {
        if let autoConnect {
            // Explicitly enabling the new switch opts into connecting on any network.
            return autoConnect ? [NEOnDemandRuleConnect()] : []
        }
        guard onDemand else { return [] }
        // Existing domain-scoped profiles keep their original behavior until the user
        // changes the new switch. Merely loading or saving must not broaden the rule.
        let evaluate = NEOnDemandRuleEvaluateConnection()
        let rule = NEEvaluateConnectionRule(matchDomains: domainList, andAction: .connectIfNeeded)
        if !probeURL.isEmpty { rule.probeURL = URL(string: probeURL) }
        evaluate.connectionRules = [rule]
        return [evaluate]
    }
}
