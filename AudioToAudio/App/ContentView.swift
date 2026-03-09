import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AudioToAudioViewModel()
    @State private var isAdvancedExpanded = false
    @State private var isFileImporterPresented = false
    @State private var isFileExporterPresented = false
    @State private var selectedPaywallPlanID: String?
    @State private var stepHelp: WorkflowStepHelp?
    @State private var stepHelpNonce = 0
    @State private var isRestartConfirmationPresented = false
#if DEBUG
    @State private var isDebugResetDialogPresented = false
#endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                background
                    .zIndex(0)

                VStack(spacing: 14) {
                    header
                    stepRail

                    Group {
                        switch viewModel.workflowStep {
                        case .source:
                            sourceStep
                        case .trim:
                            trimStep
                        case .result:
                            resultStep
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .zIndex(1)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.workflowStep)
        .onAppear {
            syncShowcaseUIState()
        }
        .onChange(of: viewModel.pickerItem) { _, _ in
            Task {
                await viewModel.handlePickerChange()
            }
        }
        .onChange(of: viewModel.showcaseStepID) { _, _ in
            syncShowcaseUIState()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                .audio,
                .mp3,
                .mpeg4Audio,
                .wav,
                .aiff,
                .movie,
                .video,
                .mpeg4Movie,
                .quickTimeMovie
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.handleImportedFile(url: url)
                }
            case .failure(let error):
                viewModel.handleImportFailure(error.localizedDescription)
            }
        }
        .sheet(isPresented: $isFileExporterPresented) {
            if let url = viewModel.trimmedAudioURL {
                FileExporterView(url: url)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isPaywallPresented },
                set: { isPresented in
                    if isPresented {
                        viewModel.presentPaywall()
                    } else {
                        viewModel.dismissPaywall()
                    }
                }
            )
        ) {
            paywallSheet
        }
        .alert(L10n.tr("Start with a new video?"), isPresented: $isRestartConfirmationPresented) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Reset"), role: .destructive) {
                viewModel.restart()
            }
        } message: {
            Text(L10n.tr("This will clear the selected source video and current conversion results."))
        }
#if DEBUG
        .background(
            DebugShakeDetector {
                if !isDebugResetDialogPresented {
                    isDebugResetDialogPresented = true
                }
            }
        )
        .confirmationDialog(
            L10n.tr("Debug: reset limits?"),
            isPresented: $isDebugResetDialogPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Reset"), role: .destructive) {
                viewModel.debugResetLimitsForTesting()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("This is available only in Debug builds."))
        }
#endif
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.03, green: 0.05, blue: 0.1), Color(red: 0.05, green: 0.08, blue: 0.16)]
                    : [Color(red: 0.95, green: 0.98, blue: 1.0), Color(red: 0.9, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.11, green: 0.73, blue: 0.62).opacity(colorScheme == .dark ? 0.18 : 0.1))
                .frame(width: 300, height: 300)
                .blur(radius: 34)
                .offset(x: -200, y: -430)

            Circle()
                .fill(Color(red: 0.2, green: 0.6, blue: 1.0).opacity(colorScheme == .dark ? 0.18 : 0.08))
                .frame(width: 340, height: 340)
                .blur(radius: 44)
                .offset(x: 210, y: 460)

            AngularGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.02 : 0.08),
                    Color.clear,
                    Color.white.opacity(colorScheme == .dark ? 0.01 : 0.05),
                    Color.clear
                ],
                center: .top,
                angle: .degrees(140)
            )
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16), radius: 10, x: 0, y: 5)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("app.title"))
                    .font(.system(size: 29, weight: .black, design: .rounded))
                    .tracking(-0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(L10n.tr("app.subtitle"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            premiumHeaderButton
                .padding(.top, 1)
        }
    }

    private var stepRail: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                workflowPill(
                    title: L10n.tr("step.source"),
                    icon: "music.note",
                    isActive: viewModel.workflowStep == .source,
                    isCompleted: viewModel.workflowStep != .source,
                    help: .source
                )

                workflowPill(
                    title: L10n.tr("step.trim"),
                    icon: "slider.horizontal.3",
                    isActive: viewModel.workflowStep == .trim,
                    isCompleted: viewModel.workflowStep == .result,
                    help: .trim
                )

                workflowPill(
                    title: L10n.tr("step.result"),
                    icon: "checkmark.circle",
                    isActive: viewModel.workflowStep == .result,
                    isCompleted: false,
                    help: .result
                )
            }

            if let help = stepHelp {
                StepHelpPopover(
                    title: L10n.tr(help.titleKey),
                    message: help.message,
                    icon: help.iconName
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
                )
            }
        }
    }

    private func workflowPill(
        title: String,
        icon: String,
        isActive: Bool,
        isCompleted: Bool,
        help: WorkflowStepHelp
    ) -> some View {
        let emphasized = isActive || isCompleted

        return Button {
            showStepHelp(help)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(
                                emphasized
                                    ? AnyShapeStyle(accentGradient)
                                    : AnyShapeStyle(Color.primary.opacity(0.09))
                            )
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .padding(.horizontal, 0)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        emphasized
                            ? Color(red: 0.17, green: 0.69, blue: 0.88).opacity(0.28)
                            : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func showStepHelp(_ help: WorkflowStepHelp) {
        if stepHelp == help {
            withAnimation(.easeOut(duration: 0.18)) {
                stepHelp = nil
            }
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            stepHelp = help
        }

        stepHelpNonce += 1
        let currentNonce = stepHelpNonce

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            guard currentNonce == stepHelpNonce else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                stepHelp = nil
            }
        }
    }

    private func stepNode(title: String, icon: String, isActive: Bool, isCompleted: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle((isActive || isCompleted) ? Color.white : Color.primary.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(
                            (isActive || isCompleted)
                                ? AnyShapeStyle(accentGradient)
                                : AnyShapeStyle(Color.primary.opacity(0.1))
                        )
                )

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle((isActive || isCompleted) ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity)
    }

    private func stepConnector(isActive: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(
                isActive
                    ? AnyShapeStyle(accentGradient)
                    : AnyShapeStyle(Color.primary.opacity(0.12))
            )
            .frame(width: 18, height: 3)
    }

    private var sourceStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                sourceExplanationCard

                VStack(spacing: 10) {
                    pickFromPhotosButton
                    pickFromFilesButton
                }

                if viewModel.hasPremiumAccess {
                    manageSubscriptionsInlineButton
                }

                if viewModel.isLoadingSourceDetails, viewModel.sourceMetadata == nil {
                    card {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.tr("status.reading_metadata"))
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    errorRow(error)
                }

                if viewModel.sourceMetadata != nil {
                    sourceSummaryCard

                    Button {
                        viewModel.sourceToTrim()
                    } label: {
                        actionButton(title: L10n.tr("action.continue"), icon: "arrow.right.circle.fill", primary: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .padding(.bottom, 14)
        }
    }

    private var sourceExplanationCard: some View {
        card(highlight: true, backgroundOpacity: 1, showsShadow: false) {
            Text(L10n.tr("status.pick_source"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var premiumHeaderButton: some View {
        Button {
            if viewModel.hasPremiumAccess {
                openManageSubscriptions()
            } else {
                viewModel.presentPaywall()
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color(red: 0.89, green: 0.65, blue: 0.03))
                    .frame(width: 42, height: 42)

                if viewModel.hasPremiumAccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.39, blue: 0.02), Color.white)
                        .background(Color.clear)
                        .offset(x: 3, y: 3)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.95, blue: 0.76).opacity(colorScheme == .dark ? 0.24 : 0.82),
                                Color(red: 0.97, green: 0.89, blue: 0.63).opacity(colorScheme == .dark ? 0.2 : 0.78),
                                Color(red: 0.95, green: 0.83, blue: 0.53).opacity(colorScheme == .dark ? 0.18 : 0.74)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        PremiumCTASecondaryShimmer(cornerRadius: 13)
                            .allowsHitTesting(false)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color(red: 0.9, green: 0.74, blue: 0.16).opacity(colorScheme == .dark ? 0.42 : 0.86), lineWidth: 1)
                    )
            )
            .frame(width: 42, height: 42)
            .shadow(color: Color(red: 0.92, green: 0.75, blue: 0.14).opacity(colorScheme == .dark ? 0.05 : 0.09), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.hasPremiumAccess ? L10n.tr("Premium Active") : L10n.tr("Premium"))
    }

    @ViewBuilder
    private var manageSubscriptionsInlineButton: some View {
        Button {
            openManageSubscriptions()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("You can manage subscriptions in Apple ID settings."))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.45 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openManageSubscriptions() {
        if let manageSubscriptionsURL {
            openURL(manageSubscriptionsURL)
        }
    }

    private func syncShowcaseUIState() {
        if viewModel.shouldAutoExpandAdvancedSettingsForShowcase {
            isAdvancedExpanded = true
        }
    }

    private func scrollToAdvancedShowcaseIfNeeded(proxy: ScrollViewProxy) {
        guard viewModel.shouldAutoExpandAdvancedSettingsForShowcase else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.linear(duration: 0.01)) {
                proxy.scrollTo("trim-advanced-settings-card", anchor: .top)
            }
        }
    }

    private var trimStep: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Button {
                            viewModel.stepBackToSource()
                        } label: {
                            iconActionButton(icon: "arrow.left.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("action.back"))

                        Button {
                            viewModel.restart()
                        } label: {
                            iconActionButton(icon: "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("action.reset"))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    trimWaveformEditorCard

                    card {
                        VStack(alignment: .leading, spacing: 10) {
                            menuRow(
                                title: L10n.tr("trim.file_type"),
                                icon: "music.note.list",
                                selection: $viewModel.selectedFileTypeID,
                                options: viewModel.fileTypeOptions,
                                showcaseListOpen: viewModel.shouldShowShowcaseFormatList
                            )

                            if let summary = viewModel.planSummaryText {
                                Text(summary)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let validationMessage = viewModel.validationMessage {
                        errorRow(validationMessage)
                    }

                    if viewModel.isTrimming {
                        card(highlight: true) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ProgressView(value: viewModel.trimProgress)
                                    if let text = viewModel.trimProgressText {
                                        Text(text)
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Button {
                                    viewModel.cancelTrim()
                                } label: {
                                    actionButton(
                                        title: viewModel.isCancellingTrim ? L10n.tr("action.cancelling") : L10n.tr("action.cancel_trim"),
                                        icon: "xmark.circle.fill",
                                        primary: false,
                                        isDestructive: true,
                                        compact: true
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!viewModel.canCancelTrim)
                            }
                        }
                    } else {
                        Button {
                            Task {
                                await viewModel.trim()
                            }
                        } label: {
                            actionButton(title: L10n.tr("action.trim_audio"), icon: "arrow.triangle.2.circlepath.circle.fill", primary: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canTrim)
                        .opacity(viewModel.canTrim ? 1 : 0.5)
                    }

                    card {
                        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                            VStack(alignment: .leading, spacing: 10) {
                                sliderRow(
                                    title: L10n.fmt("trim.fade_in_value", formatSeconds(viewModel.fadeInSeconds)),
                                    value: $viewModel.fadeInSeconds,
                                    range: 0...max(0, viewModel.effectiveClipDurationSeconds / 2)
                                )

                                sliderRow(
                                    title: L10n.fmt("trim.fade_out_value", formatSeconds(viewModel.fadeOutSeconds)),
                                    value: $viewModel.fadeOutSeconds,
                                    range: 0...max(0, viewModel.effectiveClipDurationSeconds / 2)
                                )

                                HStack(alignment: .center, spacing: 10) {
                                    Text(L10n.tr("trim.optimize_network"))
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer(minLength: 10)

                                    Toggle("", isOn: $viewModel.optimizeForNetworkUse)
                                        .labelsHidden()
                                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.14, green: 0.72, blue: 0.64)))
                                        .padding(.trailing, 2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                            }
                            .padding(.top, 8)
                        } label: {
                            Label(L10n.tr("trim.boundary_title"), systemImage: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                    }
                    .id("trim-advanced-settings-card")

                    if let error = viewModel.errorMessage {
                        errorRow(error)
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, 14)
            }
            .onAppear {
                scrollToAdvancedShowcaseIfNeeded(proxy: proxy)
            }
            .onChange(of: viewModel.showcaseStepID) { _, _ in
                scrollToAdvancedShowcaseIfNeeded(proxy: proxy)
            }
        }
    }

    private var resultStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                card(highlight: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("result.ready"), systemImage: "checkmark.seal.fill")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.12, green: 0.74, blue: 0.63))

                        if let summary = viewModel.planSummaryText {
                            Label(summary, systemImage: "gearshape.2.fill")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            if viewModel.trimmedAudioURL != nil {
                                Button {
                                    viewModel.toggleResultPreviewPlayback()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color(red: 0.10, green: 0.78, blue: 0.70),
                                                        Color(red: 0.23, green: 0.60, blue: 0.98)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )

                                        Circle()
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1.4)
                                            .padding(2)

                                        Image(systemName: viewModel.isResultPreviewPlaying ? "stop.fill" : "play.fill")
                                            .font(.system(size: 24, weight: .black))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 68, height: 68)
                                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14), radius: 8, x: 0, y: 4)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer(minLength: 0)

                            if let size = viewModel.outputSizeText {
                                statPill(icon: "internaldrive", text: size)
                            }
                        }
                    }
                }

                if let url = viewModel.trimmedAudioURL {
                    card {
                        VStack(spacing: 10) {
                            ShareLink(item: url) {
                                actionButton(title: L10n.tr("action.share_audio"), icon: "square.and.arrow.up", primary: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                isFileExporterPresented = true
                            } label: {
                                actionButton(title: L10n.tr("action.save_files"), icon: "externaldrive.badge.plus", primary: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    isRestartConfirmationPresented = true
                } label: {
                    actionButton(title: L10n.tr("New video"), icon: "arrow.counterclockwise.circle.fill", primary: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.bottom, 14)
        }
    }

    private var sourceSummaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                if let energy = viewModel.energyAnalysis {
                    WaveformStrip(
                        bins: energy.waveformBins,
                        startRatio: normalizedStartRatio,
                        endRatio: normalizedEndRatio
                    )
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let summary = viewModel.sourceSummaryText {
                            Text(summary)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)

                    if let size = viewModel.sourceSizeText {
                        statPill(icon: "internaldrive", text: size)
                    }
                }
            }
        }
    }

    private var trimWaveformEditorCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if let energy = viewModel.energyAnalysis,
                   let duration = viewModel.sourceMetadata?.durationSeconds
                {
                    TrimWaveformEditor(
                        bins: energy.waveformBins,
                        duration: duration,
                        start: Binding(
                            get: { viewModel.clipStartSeconds },
                            set: { viewModel.setTrimStart($0) }
                        ),
                        end: Binding(
                            get: { viewModel.effectiveClipEndSeconds },
                            set: { viewModel.setTrimEnd($0) }
                        ),
                        playhead: Binding(
                            get: { viewModel.previewPlayheadSeconds },
                            set: { viewModel.movePreviewPlayhead(to: $0) }
                        ),
                        isPlaying: viewModel.isPreviewPlaying,
                        onTogglePlay: {
                            viewModel.togglePreviewPlayback()
                        }
                    )
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        fixedTrimStatPill(icon: "arrow.forward.to.line", text: formatSeconds(viewModel.clipStartSeconds))
                        fixedTrimStatPill(icon: "arrow.backward.to.line", text: formatSeconds(trimRightCutSeconds))
                        fixedTrimStatPill(icon: "timer", text: formatSeconds(viewModel.effectiveClipDurationSeconds))
                        if let size = viewModel.sourceSizeText {
                            statPill(icon: "internaldrive", text: size)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let summary = viewModel.sourceSummaryText {
                    Text(summary)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionEyebrow(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
    }

    private var pickFromPhotosButton: some View {
        PhotosPicker(
            selection: $viewModel.pickerItem,
            matching: .videos,
            preferredItemEncoding: .compatible,
            photoLibrary: .shared()
        ) {
            sourceActionButton(title: L10n.tr("action.pick_photos"), icon: "photo.on.rectangle", primary: true)
        }
        .buttonStyle(.plain)
    }

    private var pickFromFilesButton: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            sourceActionButton(title: L10n.tr("action.pick_files"), icon: "folder", primary: false)
        }
        .buttonStyle(.plain)
    }

    private var normalizedStartRatio: Double {
        guard let duration = viewModel.sourceMetadata?.durationSeconds, duration > 0 else {
            return 0
        }
        return min(1, max(0, viewModel.clipStartSeconds / duration))
    }

    private var normalizedEndRatio: Double {
        guard let duration = viewModel.sourceMetadata?.durationSeconds, duration > 0 else {
            return 1
        }
        return min(1, max(0, viewModel.effectiveClipEndSeconds / duration))
    }

    private func errorRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(uiColor: .systemRed))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemRed).opacity(0.1))
            )
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            Slider(value: value, in: range)
                .tint(Color(red: 0.14, green: 0.72, blue: 0.64))
        }
    }

    private func card<Content: View>(
        highlight: Bool = false,
        backgroundOpacity: Double? = nil,
        showsShadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        Color(uiColor: .secondarySystemBackground)
                            .opacity(backgroundOpacity ?? (colorScheme == .dark ? 0.84 : 0.95))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        highlight
                            ? Color(red: 0.17, green: 0.69, blue: 0.88).opacity(0.32)
                            : Color.primary.opacity(0.09),
                        lineWidth: highlight ? 1.2 : 1
                    )
            )
            .shadow(
                color: showsShadow ? .black.opacity(colorScheme == .dark ? 0.3 : 0.08) : .clear,
                radius: showsShadow ? 12 : 0,
                x: 0,
                y: showsShadow ? 6 : 0
            )
    }

    private func actionButton(
        title: String,
        icon: String,
        primary: Bool,
        isDestructive: Bool = false,
        compact: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: compact ? 12 : 13, weight: .bold))
                .frame(width: compact ? 26 : 28, height: compact ? 26 : 28)
                .background(
                    Circle()
                        .fill(primary ? Color.white.opacity(0.18) : Color.primary.opacity(0.09))
                )

            Text(title)
                .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)

            if primary && !compact {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(primary ? Color.white : (isDestructive ? Color(uiColor: .systemRed) : Color.primary))
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .fill(
                    primary
                        ? AnyShapeStyle(accentGradient)
                        : AnyShapeStyle(Color.primary.opacity(isDestructive ? 0.1 : 0.07))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .stroke(Color.white.opacity(primary ? 0.24 : 0), lineWidth: 1)
        )
        .shadow(
            color: primary
                ? Color(red: 0.11, green: 0.68, blue: 0.78).opacity(colorScheme == .dark ? 0.34 : 0.24)
                : .clear,
            radius: primary ? 10 : 0,
            x: 0,
            y: primary ? 5 : 0
        )
    }

    private func sourceActionButton(title: String, icon: String, primary: Bool) -> some View {
        let secondaryBackground = colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color.white

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(primary ? Color.white.opacity(0.2) : Color(uiColor: .systemGray5))
                )

            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .opacity(primary ? 0.85 : 0.55)
        }
        .foregroundStyle(primary ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    primary
                        ? AnyShapeStyle(accentGradient)
                        : AnyShapeStyle(secondaryBackground)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    primary
                        ? Color.white.opacity(0.2)
                        : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        )
    }

    private func iconActionButton(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    private func menuRow(title: String, icon: String, selection: Binding<String>, options: [OutputPresetOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
        }
    }

    private func menuRow(
        title: String,
        icon: String,
        selection: Binding<String>,
        options: [OutputFileTypeOption],
        showcaseListOpen: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )

            if showcaseListOpen {
                let previewOptions = options
                VStack(spacing: 0) {
                    ForEach(previewOptions.indices, id: \.self) { index in
                        let option = previewOptions[index]
                        HStack(spacing: 8) {
                            Text(option.title)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if selection.wrappedValue == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(red: 0.14, green: 0.72, blue: 0.64))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            (selection.wrappedValue == option.id ? Color.primary.opacity(0.06) : Color.clear)
                        )

                        if index < previewOptions.count - 1 {
                            Divider()
                                .overlay(Color.primary.opacity(0.08))
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 8, x: 0, y: 4)
                .padding(.top, 4)
            }
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.76, blue: 0.67),
                Color(red: 0.22, green: 0.58, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var currentStepTitle: String {
        switch viewModel.workflowStep {
        case .source:
            return L10n.tr("step.source")
        case .trim:
            return L10n.tr("step.trim")
        case .result:
            return L10n.tr("step.result")
        }
    }

    private var currentStepIcon: String {
        switch viewModel.workflowStep {
        case .source:
            return "music.note"
        case .trim:
            return "arrow.triangle.2.circlepath"
        case .result:
            return "checkmark.circle.fill"
        }
    }

    private var paywallSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: paywallBackgroundGradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "crown.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .systemYellow))
                                Text(L10n.tr("Unlock Unlimited Usage"))
                                    .font(.title2.weight(.bold))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(paywallPrimaryTextColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 14) {
                            ForEach(viewModel.purchaseOptions) { option in
                                paywallPlanCard(option: option, isSelected: option.id == selectedPaywallPlanID)
                            }

                            if viewModel.purchaseOptions.isEmpty {
                                ProgressView()
                                    .tint(paywallPrimaryTextColor)
                                    .padding(.vertical, 8)
                            }
                        }

                        Button {
                            guard let selectedPaywallPlanID else { return }
                            Task {
                                await viewModel.purchasePlan(planID: selectedPaywallPlanID)
                            }
                        } label: {
                            Text(viewModel.isPurchasingPlan ? L10n.tr("Processing...") : L10n.tr("Continue"))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .padding(.horizontal, 18)
                                .background(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0xFE / 255, green: 0x68 / 255, blue: 0x71 / 255),
                                            Color(red: 0xFF / 255, green: 0xA3 / 255, blue: 0x6B / 255)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(paywallCTAStrokeColor, lineWidth: 1)
                                )
                                .shadow(color: paywallCTAShadowColor, radius: 14, x: 0, y: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isPurchasingPlan || selectedPaywallPlanID == nil)

                        Button {
                            Task {
                                await viewModel.restorePurchases()
                            }
                        } label: {
                            Text(L10n.tr("Restore Purchases"))
                                .font(.subheadline.weight(.semibold))
                                .underline()
                                .foregroundStyle(paywallPrimaryTextColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isPurchasingPlan)

                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color(uiColor: .systemRed))
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 6) {
                            Text(L10n.tr("Auto-renewable plans renew unless canceled 24 hours before period end."))
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallTertiaryTextColor)
                            HStack(spacing: 14) {
                                if let termsOfUseURL {
                                    Link(L10n.tr("Terms"), destination: termsOfUseURL)
                                }
                                if let privacyPolicyURL {
                                    Link(L10n.tr("Privacy"), destination: privacyPolicyURL)
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .tint(paywallPrimaryTextColor)

                            if let manageSubscriptionsURL {
                                Link(L10n.tr("You can manage subscriptions in Apple ID settings."), destination: manageSubscriptionsURL)
                                    .font(.caption2.weight(.semibold))
                                    .underline()
                                    .multilineTextAlignment(.center)
                                    .tint(paywallPrimaryTextColor)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 30)
                }
            }
            .onAppear {
                normalizeSelectedPaywallSelection()
            }
            .onChange(of: viewModel.purchaseOptions) { _, _ in
                normalizeSelectedPaywallSelection()
            }
            .navigationTitle(L10n.tr("Premium"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.dismissPaywall()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(paywallSecondaryTextColor)
                    }
                }
            }
        }
    }

    private func preferredPaywallPlanID() -> String? {
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .monthly && $0.isAvailable
        })?.id {
            return id
        }
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .lifetime && $0.isAvailable
        })?.id {
            return id
        }
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .weekly && $0.isAvailable
        })?.id {
            return id
        }
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .monthly
        })?.id {
            return id
        }
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .lifetime
        })?.id {
            return id
        }
        if let id = viewModel.purchaseOptions.first(where: {
            PurchaseManager.planKind(for: $0.id) == .weekly
        })?.id {
            return id
        }
        return viewModel.purchaseOptions.first?.id
    }

    private func normalizeSelectedPaywallSelection() {
        if let selectedPaywallPlanID,
           viewModel.purchaseOptions.contains(where: { $0.id == selectedPaywallPlanID })
        {
            return
        }
        selectedPaywallPlanID = preferredPaywallPlanID()
    }

    private func paywallPlanCard(option: PurchasePlanOption, isSelected: Bool) -> some View {
        let accent = paywallAccent(for: option.id)
        return Button {
            selectedPaywallPlanID = option.id
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.title)
                            .font(.headline)
                            .foregroundStyle(paywallPrimaryTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .layoutPriority(1)
                        if let badge = paywallBadge(for: option.id) {
                            paywallBadgeChip(
                                title: badge,
                                fill: accent.opacity(0.9),
                                stroke: Color.white.opacity(0.35),
                                textColor: .white,
                                showsStroke: true
                            )
                        }
                        if !option.isAvailable {
                            paywallBadgeChip(
                                title: L10n.tr("Unavailable"),
                                fill: Color(uiColor: .systemGray),
                                stroke: Color.clear,
                                textColor: .white,
                                showsStroke: false
                            )
                        }
                    }

                    Text(option.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(paywallSecondaryTextColor)

                    if !option.priceText.isEmpty {
                        Text(option.priceText)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(paywallPrimaryTextColor)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(accent)
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(paywallSecondaryTextColor.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isSelected
                            ? accent.opacity(colorScheme == .dark ? 0.2 : 0.16)
                            : paywallCardFillColor
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? accent : paywallCardStrokeColor,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .opacity(option.isAvailable ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPurchasingPlan)
    }

    private func paywallAccent(for planID: String) -> Color {
        switch PurchaseManager.planKind(for: planID) {
        case .weekly:
            return Color(red: 0.27, green: 0.52, blue: 0.98)
        case .monthly:
            return Color(red: 0.62, green: 0.38, blue: 0.96)
        case .lifetime:
            return Color(red: 0.96, green: 0.56, blue: 0.22)
        case .unknown:
            return Color(red: 0.40, green: 0.48, blue: 0.72)
        }
    }

    private func paywallBadge(for planID: String) -> String? {
        switch PurchaseManager.planKind(for: planID) {
        case .monthly:
            return L10n.tr("Most popular")
        case .lifetime:
            return L10n.tr("Best value")
        case .weekly, .unknown:
            return nil
        }
    }

    private func paywallBadgeChip(
        title: String,
        fill: Color,
        stroke: Color,
        textColor: Color,
        showsStroke: Bool
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: showsStroke ? 1 : 0))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var termsOfUseURL: URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "TERMS_OF_USE_URL") as? String,
           let url = URL(string: configured), !configured.isEmpty
        {
            return url
        }
        return URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    private var privacyPolicyURL: URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "PRIVACY_POLICY_URL") as? String,
           let url = URL(string: configured), !configured.isEmpty
        {
            return url
        }
        return nil
    }

    private var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private var paywallBackgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.11, green: 0.12, blue: 0.22),
                Color(red: 0.11, green: 0.17, blue: 0.33)
            ]
        }
        return [
            Color(red: 0.96, green: 0.98, blue: 1.0),
            Color(red: 0.90, green: 0.94, blue: 1.0)
        ]
    }

    private var paywallPrimaryTextColor: Color {
        colorScheme == .dark ? .white : Color(uiColor: .label)
    }

    private var paywallSecondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.82) : Color(uiColor: .secondaryLabel)
    }

    private var paywallTertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.68) : Color(uiColor: .tertiaryLabel)
    }

    private var paywallCardFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.8)
    }

    private var paywallCardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
    }

    private var paywallCTAStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.1)
    }

    private var paywallCTAShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.28) : .black.opacity(0.14)
    }

    private func statPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func fixedTrimStatPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 50, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 80, alignment: .center)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private var trimRightCutSeconds: Double {
        guard let totalDuration = viewModel.sourceMetadata?.durationSeconds else {
            return 0
        }
        return max(0, totalDuration - viewModel.effectiveClipEndSeconds)
    }

}

private struct PremiumCTAPrimaryShimmer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInitialState = true

    let cornerRadius: CGFloat

    private var min: CGFloat { -0.28 }
    private var max: CGFloat { 1.28 }

    private var shimmerStartPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            return isInitialState ? UnitPoint(x: max, y: min) : UnitPoint(x: 0, y: 1)
        }
        return isInitialState ? UnitPoint(x: min, y: min) : UnitPoint(x: 1, y: 1)
    }

    private var shimmerEndPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            return isInitialState ? UnitPoint(x: 1, y: 0) : UnitPoint(x: min, y: max)
        }
        return isInitialState ? UnitPoint(x: 0, y: 0) : UnitPoint(x: max, y: max)
    }

    private var highlightColor: Color {
        colorScheme == .dark ? .white.opacity(0.26) : .white.opacity(0.58)
    }

    var body: some View {
        LinearGradient(
            colors: [.clear, highlightColor, .clear],
            startPoint: shimmerStartPoint,
            endPoint: shimmerEndPoint
        )
        .blendMode(.screen)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .compositingGroup()
        .opacity(reduceMotion ? 0 : 1)
        .animation(
            .linear(duration: 2.2)
                .delay(0.25)
                .repeatForever(autoreverses: false),
            value: isInitialState
        )
        .onAppear {
            guard !reduceMotion else { return }
            DispatchQueue.main.async {
                isInitialState = false
            }
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue {
                isInitialState = true
                return
            }
            DispatchQueue.main.async {
                isInitialState = false
            }
        }
    }
}

private struct PremiumCTASecondaryShimmer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    let cornerRadius: CGFloat

    private var highlightColor: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .white.opacity(0.32)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let shimmerWidth = max(width * 0.24, 58)
            let travel = width + shimmerWidth * 2

            LinearGradient(
                colors: [.clear, highlightColor, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: shimmerWidth, height: height * 1.7)
            .rotationEffect(.degrees(18))
            .offset(x: (phase * travel) - shimmerWidth)
            .onAppear {
                guard !reduceMotion else { return }
                phase = -0.4
                withAnimation(
                    .linear(duration: 2.4)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 1.4
                }
            }
            .onChange(of: reduceMotion) { _, newValue in
                if newValue {
                    phase = -0.4
                    return
                }
                phase = -0.4
                withAnimation(
                    .linear(duration: 2.4)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 1.4
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

private enum WorkflowStepHelp: String, Identifiable {
    case source
    case trim
    case result

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .source:
            return "step.source"
        case .trim:
            return "step.trim"
        case .result:
            return "step.result"
        }
    }

    var iconName: String {
        switch self {
        case .source:
            return "music.note"
        case .trim:
            return "slider.horizontal.3"
        case .result:
            return "checkmark.circle"
        }
    }

    var message: String {
        switch self {
        case .source:
            return L10n.tr("status.pick_source")
        case .trim:
            return [
                L10n.tr("trim.file_type"),
                L10n.tr("trim.boundary_title"),
                L10n.tr("action.trim_audio")
            ].joined(separator: " • ")
        case .result:
            return L10n.tr("help.result.message")
        }
    }
}

private struct StepHelpPopover: View {
    let title: String
    let message: String
    let icon: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.17, green: 0.69, blue: 0.88))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color(red: 0.17, green: 0.69, blue: 0.88).opacity(colorScheme == .dark ? 0.2 : 0.14))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.1), radius: 8, x: 0, y: 4)
        .allowsHitTesting(false)
    }
}

#if DEBUG
private struct DebugShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> DebugShakeViewController {
        let controller = DebugShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ uiViewController: DebugShakeViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

private final class DebugShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resignFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        onShake?()
    }
}
#endif

private struct WaveformStrip: View {
    let bins: [Double]
    let startRatio: Double
    let endRatio: Double

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !bins.isEmpty else { return }

                let selectionStart = size.width * startRatio
                let selectionEnd = size.width * endRatio
                let selectionRect = CGRect(
                    x: selectionStart,
                    y: 0,
                    width: max(0, selectionEnd - selectionStart),
                    height: size.height
                )

                context.fill(
                    Path(roundedRect: selectionRect, cornerRadius: 5),
                    with: .color(Color(red: 0.18, green: 0.72, blue: 0.94).opacity(0.12))
                )

                let barWidth = max(1, size.width / CGFloat(max(bins.count, 1)))
                for (index, amplitude) in bins.enumerated() {
                    let ratio = Double(index) / Double(max(1, bins.count - 1))
                    let isSelected = ratio >= startRatio && ratio <= endRatio
                    let height = max(4, CGFloat(amplitude) * (size.height - 4))
                    let x = CGFloat(index) * barWidth
                    let y = (size.height - height) / 2
                    let rect = CGRect(x: x, y: y, width: max(1, barWidth - 1), height: height)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    let color = isSelected
                        ? Color(red: 0.16, green: 0.7, blue: 0.92).opacity(0.95)
                        : Color.primary.opacity(0.16)
                    context.fill(path, with: .color(color))
                }

                let markerWidth: CGFloat = 2
                let markerColor = Color(red: 0.09, green: 0.73, blue: 0.7).opacity(0.85)
                context.fill(Path(CGRect(x: selectionStart - markerWidth / 2, y: 0, width: markerWidth, height: size.height)), with: .color(markerColor))
                context.fill(Path(CGRect(x: selectionEnd - markerWidth / 2, y: 0, width: markerWidth, height: size.height)), with: .color(markerColor))
            }
        }
        .frame(height: 74)
        .padding(.vertical, 2)
    }
}

private struct TrimWaveformEditor: View {
    private enum DragTarget {
        case start
        case end
        case playhead
    }

    let bins: [Double]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double
    let isPlaying: Bool
    let onTogglePlay: () -> Void
    @State private var dragTarget: DragTarget?
    @Environment(\.colorScheme) private var colorScheme

    private let handleWidth: CGFloat = 18
    private let waveformHeight: CGFloat = 92

    private var minimumSpan: Double {
        min(0.1, max(duration, 0))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let startX = positionX(for: start, width: width)
                let endX = positionX(for: end, width: width)
                let playheadX = positionX(for: playhead, width: width)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))

                    Canvas { context, size in
                        guard !bins.isEmpty else { return }

                        let selectionStart = size.width * CGFloat(start / max(duration, 0.0001))
                        let selectionEnd = size.width * CGFloat(end / max(duration, 0.0001))
                        let selectionRect = CGRect(
                            x: selectionStart,
                            y: 0,
                            width: max(0, selectionEnd - selectionStart),
                            height: size.height
                        )

                        context.fill(
                            Path(roundedRect: selectionRect, cornerRadius: 8),
                            with: .color(Color(red: 0.18, green: 0.72, blue: 0.94).opacity(0.14))
                        )

                        let barWidth = max(1, size.width / CGFloat(max(bins.count, 1)))
                        for (index, amplitude) in bins.enumerated() {
                            let ratio = Double(index) / Double(max(1, bins.count - 1))
                            let isSelected = ratio >= (start / max(duration, 0.0001)) && ratio <= (end / max(duration, 0.0001))
                            let height = max(4, CGFloat(amplitude) * (size.height - 6))
                            let x = CGFloat(index) * barWidth
                            let y = (size.height - height) / 2
                            let rect = CGRect(x: x, y: y, width: max(1, barWidth - 1), height: height)
                            let color = isSelected
                                ? Color(red: 0.16, green: 0.7, blue: 0.92).opacity(0.95)
                                : Color.primary.opacity(0.16)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 1)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(red: 0.09, green: 0.73, blue: 0.7).opacity(0.55), lineWidth: 1)
                        .frame(width: max(8, endX - startX), height: waveformHeight - 4)
                        .offset(x: startX)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color(red: 0.93, green: 0.99, blue: 1).opacity(colorScheme == .dark ? 0.9 : 0.95))
                        .frame(width: 2, height: waveformHeight - 8)
                        .overlay(
                            Circle()
                                .fill(Color(red: 0.93, green: 0.99, blue: 1).opacity(colorScheme == .dark ? 0.95 : 1))
                                .frame(width: 9, height: 9)
                                .offset(y: -(waveformHeight / 2) + 9)
                        )
                        .offset(x: playheadX - 1, y: 0)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 2, x: 0, y: 1)
                        .allowsHitTesting(false)

                    boundaryHandle
                        .offset(x: startX - (handleWidth / 2), y: (waveformHeight - 36) / 2)

                    boundaryHandle
                        .offset(x: endX - (handleWidth / 2), y: (waveformHeight - 36) / 2)
                }
                .frame(height: waveformHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragTarget == nil {
                                dragTarget = dragTargetForTouch(
                                    x: value.startLocation.x,
                                    startX: startX,
                                    endX: endX
                                )
                            }

                            let candidate = valueAt(positionX: value.location.x, width: width)
                            switch dragTarget ?? .playhead {
                            case .start:
                                let boundedStart = min(max(0, candidate), max(0, end - minimumSpan))
                                start = boundedStart
                                if playhead < start {
                                    playhead = start
                                }
                            case .end:
                                let boundedEnd = max(min(duration, candidate), min(duration, start + minimumSpan))
                                end = boundedEnd
                                if playhead > end {
                                    playhead = end
                                }
                            case .playhead:
                                playhead = clamped(candidate, in: start...end)
                            }
                        }
                        .onEnded { _ in
                            dragTarget = nil
                        }
                )
            }
            .frame(height: waveformHeight)

            HStack(spacing: 8) {
                Button {
                    onTogglePlay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))

                        Text(formatSeconds(playhead))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
    }

    private var boundaryHandle: some View {
        Capsule(style: .continuous)
            .fill(Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.92 : 0.98))
            .frame(width: handleWidth, height: 36)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.34 : 0.18), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 2, height: 13)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.1), radius: 4, x: 0, y: 2)
    }

    private func positionX(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let ratio = min(1, max(0, value / duration))
        return width * ratio
    }

    private func valueAt(positionX: CGFloat, width: CGFloat) -> Double {
        let ratio = min(1, max(0, positionX / width))
        return Double(ratio) * duration
    }

    private func dragTargetForTouch(x: CGFloat, startX: CGFloat, endX: CGFloat) -> DragTarget {
        let hitSlop: CGFloat = 18
        if abs(x - startX) <= hitSlop {
            return .start
        }
        if abs(x - endX) <= hitSlop {
            return .end
        }
        return .playhead
    }
}

private struct FileExporterView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
