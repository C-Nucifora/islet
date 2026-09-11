import SwiftUI

struct ContextRulesSettingsView: View {
  @ObservedObject private var center = ContextRuleCenter.shared
  @State private var editingRule: ContextRule?
  @State private var overridePulse: PulseDeliveryProfile?
  @State private var overrideEnergy: EnergyMode?
  @State private var overrideHiddenActivities: Set<String> = []
  @State private var overrideDuration: TimeInterval = 60 * 60

  var body: some View {
    Form {
      Section("Current context") {
        if let title = center.resolution.title, let reason = center.resolution.reason {
          LabeledContent("Active rule") { Text(title).foregroundStyle(.secondary) }
          LabeledContent("Matched because") { Text(reason).foregroundStyle(.secondary) }
          LabeledContent("Changes") {
            Text(center.resolution.action?.summary() ?? "No changes")
              .foregroundStyle(.secondary)
          }
        } else {
          Label("No rule matches. Saved settings are in use.", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
        }
        Text(
          "Matching happens on this Mac. Islet does not send Focus, app, display, time or Wi-Fi context to providers."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section("Rules") {
        Text("The first enabled matching rule wins. Drag rules to change precedence.")
          .font(.caption).foregroundStyle(.secondary)
        if center.rules.isEmpty {
          ContentUnavailableView(
            "No context rules", systemImage: "switch.2",
            description: Text("Add a rule to adapt Pulse, energy use or activity visibility."))
        } else {
          List {
            ForEach(center.rules) { rule in
              HStack(spacing: 10) {
                Toggle("", isOn: enabledBinding(for: rule))
                  .labelsHidden()
                  .help(
                    rule.isEnabled
                      ? String(localized: "Disable \(rule.name)")
                      : String(localized: "Enable \(rule.name)"))
                VStack(alignment: .leading, spacing: 2) {
                  Text(rule.name).font(.body.weight(.medium))
                  Text("\(rule.trigger.kind.title) · \(rule.action.summary())")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Edit") { editingRule = rule }
                Button(role: .destructive) {
                  guard let index = center.rules.firstIndex(where: { $0.id == rule.id }) else {
                    return
                  }
                  center.delete(at: IndexSet(integer: index))
                } label: {
                  Label("Delete \(rule.name)", systemImage: "trash")
                    .labelStyle(.iconOnly)
                }
                .help("Delete \(rule.name)")
              }
              .padding(.vertical, 3)
            }
            .onMove(perform: center.move)
            .onDelete(perform: center.delete)
          }
          .frame(minHeight: 150, idealHeight: 230)
        }
        Button {
          editingRule = ContextRule(
            name: "New rule", trigger: ContextRuleTrigger(),
            action: ContextRuleAction(pulseDelivery: .focused))
        } label: {
          Label("Add rule", systemImage: "plus")
        }
        .disabled(center.rules.count >= ContextRule.maximumCount)
      }

      Section("Temporary manual override") {
        if let manualOverride = center.manualOverride,
          manualOverride.isActive(at: Date())
        {
          LabeledContent("Expires") {
            Text(manualOverride.expiresAt, style: .relative).foregroundStyle(.secondary)
          }
          Text(manualOverride.action.summary()).font(.caption).foregroundStyle(.secondary)
          Button("End override") { center.clearManualOverride() }
        } else {
          optionalPulsePicker("Pulse delivery", selection: $overridePulse)
          optionalEnergyPicker("Energy mode", selection: $overrideEnergy)
          DisclosureGroup("Activity visibility") {
            ForEach(ActivityCatalog.orderable, id: \.id) { activity in
              Toggle(
                "Hide \(activity.name)",
                isOn: overrideHiddenBinding(for: activity.id))
            }
          }
          Picker("Duration", selection: $overrideDuration) {
            Text("15 minutes").tag(TimeInterval(15 * 60))
            Text("1 hour").tag(TimeInterval(60 * 60))
            Text("4 hours").tag(TimeInterval(4 * 60 * 60))
            Text("24 hours").tag(TimeInterval(24 * 60 * 60))
          }
          Button("Start override") {
            center.setManualOverride(
              action: ContextRuleAction(
                pulseDelivery: overridePulse, energyMode: overrideEnergy,
                activityVisibility: Dictionary(
                  uniqueKeysWithValues: overrideHiddenActivities.map { ($0, false) })),
              duration: overrideDuration)
          }
          .disabled(
            overridePulse == nil && overrideEnergy == nil && overrideHiddenActivities.isEmpty)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { center.refresh() }
    .sheet(item: $editingRule) { rule in
      ContextRuleEditor(
        rule: rule, snapshot: center.snapshot,
        save: { updated in
          if center.rules.contains(where: { $0.id == updated.id }) {
            center.update(updated)
          } else {
            center.add(updated)
          }
          editingRule = nil
        }, cancel: { editingRule = nil })
    }
  }

  private func enabledBinding(for rule: ContextRule) -> Binding<Bool> {
    Binding(
      get: { center.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
      set: { center.setEnabled($0, for: rule.id) })
  }

  private func overrideHiddenBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { overrideHiddenActivities.contains(id) },
      set: { hidden in
        if hidden {
          overrideHiddenActivities.insert(id)
        } else {
          overrideHiddenActivities.remove(id)
        }
      })
  }

  @ViewBuilder
  private func optionalPulsePicker(
    _ title: String, selection: Binding<PulseDeliveryProfile?>
  ) -> some View {
    Picker(title, selection: selection) {
      Text("No change").tag(PulseDeliveryProfile?.none)
      ForEach(PulseDeliveryProfile.allCases) { profile in
        Text(profile.title).tag(Optional(profile))
      }
    }
  }

  @ViewBuilder
  private func optionalEnergyPicker(_ title: String, selection: Binding<EnergyMode?>) -> some View {
    Picker(title, selection: selection) {
      Text("No change").tag(EnergyMode?.none)
      ForEach(EnergyMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(Optional(mode))
      }
    }
  }
}

private struct ContextRuleEditor: View {
  @State private var rule: ContextRule
  let snapshot: ContextSnapshot
  let save: (ContextRule) -> Void
  let cancel: () -> Void

  init(
    rule: ContextRule, snapshot: ContextSnapshot, save: @escaping (ContextRule) -> Void,
    cancel: @escaping () -> Void
  ) {
    _rule = State(initialValue: rule)
    self.snapshot = snapshot
    self.save = save
    self.cancel = cancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Edit context rule").font(.title2.weight(.semibold))
      Form {
        Section("Rule") {
          TextField("Name", text: $rule.name)
          Toggle("Enabled", isOn: $rule.isEnabled)
          Picker("When", selection: $rule.trigger.kind) {
            ForEach(ContextTriggerKind.allCases) { kind in Text(kind.title).tag(kind) }
          }
          triggerFields
        }
        Section("Changes") {
          optionalPulsePicker
          optionalEnergyPicker
          DisclosureGroup("Activity visibility") {
            Text("Rules can hide enabled activities, but cannot turn on an activity you disabled.")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(ActivityCatalog.orderable, id: \.id) { activity in
              Toggle("Hide \(activity.name)", isOn: hiddenBinding(for: activity.id))
            }
          }
        }
        Section("Preview before saving") {
          LabeledContent("This rule will") { Text(rule.action.summary()) }
          if let reason = ContextRuleEvaluator.matchReason(for: rule.trigger, snapshot: snapshot) {
            Label("Matches now: \(reason)", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Label("Does not match the current context", systemImage: "circle.dashed")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Save rule") { save(rule) }
          .keyboardShortcut(.defaultAction)
          .disabled(!rule.isValid)
      }
    }
    .padding(24)
    .frame(minWidth: 620, minHeight: 580)
  }

  @ViewBuilder private var triggerFields: some View {
    switch rule.trigger.kind {
    case .focusMode:
      TextField("Focus name, or leave empty for any Focus", text: $rule.trigger.text)
    case .powerSource:
      Picker("Source", selection: $rule.trigger.powerSource) {
        ForEach(ContextPowerSource.allCases) { source in Text(source.title).tag(source) }
      }
    case .lowPowerMode:
      Toggle("Low Power Mode is on", isOn: $rule.trigger.boolean)
    case .frontmostApp:
      TextField("Bundle identifier, such as com.apple.Keynote", text: $rule.trigger.text)
    case .fullscreenPresentation:
      Toggle("A fullscreen presentation is active", isOn: $rule.trigger.boolean)
    case .timeRange:
      Picker("From", selection: $rule.trigger.startMinute) {
        ForEach(timeChoices, id: \.self) { minute in Text(timeLabel(minute)).tag(minute) }
      }
      Picker("Until", selection: $rule.trigger.endMinute) {
        ForEach(timeChoices, id: \.self) { minute in Text(timeLabel(minute)).tag(minute) }
      }
      Text("Ranges can cross midnight. The end time is not included.")
        .font(.caption).foregroundStyle(.secondary)
    case .activeDisplay:
      TextField("Display name or identifier", text: $rule.trigger.text)
    case .wifiNetwork:
      TextField("Wi-Fi network name", text: $rule.trigger.text)
      Text("The network name stays in local settings and is excluded from diagnostics and export.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var optionalPulsePicker: some View {
    Picker("Pulse delivery", selection: $rule.action.pulseDelivery) {
      Text("No change").tag(PulseDeliveryProfile?.none)
      ForEach(PulseDeliveryProfile.allCases) { profile in
        Text(profile.title).tag(Optional(profile))
      }
    }
  }

  private var optionalEnergyPicker: some View {
    Picker("Energy mode", selection: $rule.action.energyMode) {
      Text("No change").tag(EnergyMode?.none)
      ForEach(EnergyMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(Optional(mode))
      }
    }
  }

  private func hiddenBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { rule.action.activityVisibility[id] == false },
      set: { hidden in
        if hidden {
          rule.action.activityVisibility[id] = false
        } else {
          rule.action.activityVisibility[id] = nil
        }
      })
  }

  private var timeChoices: [Int] { Array(stride(from: 0, to: 24 * 60, by: 30)) }

  private func timeLabel(_ minute: Int) -> String {
    var components = DateComponents()
    components.hour = minute / 60
    components.minute = minute % 60
    return Calendar.current.date(from: components)?.formatted(date: .omitted, time: .shortened)
      ?? "\(minute / 60):\(String(format: "%02d", minute % 60))"
  }
}
