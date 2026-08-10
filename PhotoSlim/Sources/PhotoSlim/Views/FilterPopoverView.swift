import SwiftUI

struct FilterPopoverView: View {
  @EnvironmentObject private var model: AppModel
  @State private var exclusionExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("筛选照片图库")
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Button("重置") { model.filter = BrowserFilter() }
          .buttonStyle(.link)
      }
      .padding(16)
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Toggle("仅显示收藏", isOn: $model.filter.favoritesOnly)

          filterSection("拍摄时间") {
            Picker("时间", selection: $model.filter.timeFilter) {
              ForEach(TimeFilter.allCases) { Text($0.title).tag($0) }
            }
            if model.filter.timeFilter == .customOlderThan {
              HStack {
                TextField("年数", value: customMinimumAgeYears, format: .number)
                  .textFieldStyle(.roundedBorder)
                Text("年以上")
                  .foregroundStyle(.secondary)
              }
            } else if model.filter.timeFilter == .custom {
              DatePicker("开始", selection: customStartDate, displayedComponents: .date)
              DatePicker("结束", selection: customEndDate, displayedComponents: .date)
            }
          }

          filterSection("原文件大小") {
            Picker("大小", selection: $model.filter.sizeFilter) {
              ForEach(SizeFilter.pickerCases) { Text($0.title).tag($0) }
            }
            if model.filter.sizeFilter == .customMinimum {
              HStack {
                TextField(
                  "最小 MB", value: minimumMB, format: .number.precision(.fractionLength(0...1)))
                Text("MB 以上")
                  .foregroundStyle(.secondary)
              }
              .textFieldStyle(.roundedBorder)
            } else if model.filter.sizeFilter == .custom {
              HStack {
                TextField(
                  "最小 MB", value: minimumMB, format: .number.precision(.fractionLength(0...1)))
                Text("至").foregroundStyle(.secondary)
                TextField(
                  "最大 MB", value: maximumMB, format: .number.precision(.fractionLength(0...1)))
              }
              .textFieldStyle(.roundedBorder)
            }
          }

          filterSection("存储位置") {
            Picker("存储位置", selection: $model.filter.cloudFilter) {
              ForEach(CloudFilter.allCases) { Text($0.title).tag($0) }
            }
          }

          Divider()

          DisclosureGroup(isExpanded: $exclusionExpanded) {
            VStack(alignment: .leading, spacing: 11) {
              Text("取消排除会先显示风险提醒；锁定项目即使显示也不能处理。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              ForEach(ExclusionReason.allCases) { reason in
                Toggle(isOn: exclusionBinding(reason)) {
                  HStack(spacing: 6) {
                    Text(reason.title)
                    if reason.isHardBlock {
                      Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    }
                  }
                }
              }
            }
            .padding(.top, 11)
          } label: {
            HStack {
              Text("排除项")
                .font(.system(size: 12, weight: .semibold))
              Spacer()
              Text("默认排除风险项目")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(16)
      }
    }
    .frame(width: 390, height: 590)
    .background(PhotoSlimTheme.surface)
    .onDisappear { model.savePreferences() }
    // Keep this alert on the popover that owns the toggle. The root view also
    // presents notices; on macOS, multiple alert modifiers on the same root
    // hierarchy can leave the first alert invisible while the binding remains
    // set, making the toggle appear impossible to turn off.
    .alert(item: $model.pendingExclusionWarning) { reason in
      Alert(
        title: Text("显示“\(reason.title)”项目？"),
        message: Text(
          reason.warning
            + (reason.isHardBlock
              ? "\n\n这些项目仍然不能加入任务。"
              : "\n\n显示后，可处理项目可以由你手动加入任务。")
        ),
        primaryButton: .default(
          Text("显示这些项目"),
          action: model.confirmShowingExcludedReason
        ),
        secondaryButton: .cancel(
          Text("保持排除"),
          action: model.cancelShowingExcludedReason
        )
      )
    }
  }

  private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func exclusionBinding(_ reason: ExclusionReason) -> Binding<Bool> {
    Binding(
      get: { model.filter.excludedReasons.contains(reason) },
      set: { model.requestExclusionChange(reason, excluded: $0) }
    )
  }

  private var customStartDate: Binding<Date> {
    Binding(
      get: {
        model.filter.customStartDate ?? Calendar.current.date(
          byAdding: .year, value: -5, to: Date())!
      },
      set: { model.filter.customStartDate = $0 }
    )
  }

  private var customMinimumAgeYears: Binding<Int> {
    Binding(
      get: { max(1, model.filter.customMinimumAgeYears ?? 10) },
      set: { model.filter.customMinimumAgeYears = max(1, $0) }
    )
  }

  private var customEndDate: Binding<Date> {
    Binding(get: { model.filter.customEndDate ?? Date() }, set: { model.filter.customEndDate = $0 })
  }

  private var minimumMB: Binding<Double> {
    Binding(
      get: { Double(model.filter.customMinimumBytes ?? 0) / 1_000_000 },
      set: { model.filter.customMinimumBytes = $0 > 0 ? Int64($0 * 1_000_000) : nil }
    )
  }

  private var maximumMB: Binding<Double> {
    Binding(
      get: { Double(model.filter.customMaximumBytes ?? 0) / 1_000_000 },
      set: { model.filter.customMaximumBytes = $0 > 0 ? Int64($0 * 1_000_000) : nil }
    )
  }
}
