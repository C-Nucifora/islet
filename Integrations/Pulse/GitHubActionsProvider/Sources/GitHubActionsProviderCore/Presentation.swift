import Foundation

public enum RunPresentationBuilder {
  public static func make(
    run: WorkflowRun,
    repository: String,
    identifierScope: String? = nil,
    failedJob: WorkflowJob?,
    canRerun: Bool,
    activeExpiry: TimeInterval,
    terminalExpiry: TimeInterval
  ) -> PulsePresentation {
    let status = mappedStatus(run)
    var actions = [PulseLink(title: "Open run", url: run.htmlURL)]
    if let failedJob {
      actions.append(PulseLink(title: "Failed job", url: failedJob.htmlURL))
    }
    if status.terminal, canRerun, actions.count < 3 {
      actions.append(PulseLink(title: "Rerun in GitHub", url: run.htmlURL))
    }
    let branch = clean(run.headBranch ?? "detached", limit: 80)
    let subtitle = clean(
      "\(repository) · \(branch) · \(run.event) · attempt \(run.runAttempt)", limit: 240)
    return PulsePresentation(
      operation: status.terminal ? .event : .update,
      identifier: identifier(scope: identifierScope ?? "\(repository)#\(run.workflowID)"),
      title: clean("\(run.name) \(status.titleSuffix)", limit: 180),
      subtitle: subtitle,
      state: status.state,
      priority: status.priority,
      symbol: status.symbol,
      expiresAfter: status.terminal ? terminalExpiry : activeExpiry,
      actions: actions,
      terminal: status.terminal)
  }

  public static func health(_ failure: ProviderFailure) -> PulsePresentation {
    PulsePresentation(
      operation: .update,
      identifier: "github-actions-health",
      title: failure.healthTitle,
      subtitle: failure.healthSubtitle,
      state: "needsAction",
      priority: failure == .rateLimited ? "high" : "critical",
      symbol: failure == .authentication ? "person.badge.key.fill" : "wifi.exclamationmark",
      expiresAfter: 0,
      actions: [],
      terminal: false)
  }

  private static func mappedStatus(_ run: WorkflowRun) -> (
    titleSuffix: String, state: String, priority: String, symbol: String, terminal: Bool
  ) {
    switch run.status {
    case "queued", "requested", "waiting", "pending":
      return ("queued", "active", "normal", "clock.fill", false)
    case "in_progress":
      return ("running", "progress", "normal", "arrow.triangle.2.circlepath", false)
    case "completed":
      switch run.conclusion {
      case "success", "neutral", "skipped":
        return ("succeeded", "succeeded", "normal", "checkmark.circle.fill", true)
      case "cancelled":
        return ("cancelled", "cancelled", "low", "xmark.circle.fill", true)
      case "action_required", "stale":
        return ("needs attention", "needsAction", "high", "exclamationmark.circle.fill", true)
      case "failure", "timed_out", "startup_failure":
        return ("failed", "failed", "critical", "xmark.octagon.fill", true)
      default:
        return ("needs attention", "needsAction", "high", "questionmark.circle.fill", true)
      }
    default:
      return ("needs attention", "needsAction", "high", "questionmark.circle.fill", false)
    }
  }

  private static func identifier(scope: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in scope.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "github-actions-\(String(hash, radix: 16))"
  }

  private static func clean(_ value: String, limit: Int) -> String {
    let collapsed = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    return String(collapsed.prefix(limit))
  }
}
