import SwiftUI

struct ExportDialogView: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ui.exportDialog.title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(L("ui.exportDialog.destination"))
                        .frame(width: 110, alignment: .leading)

                    Text(workspace.exportDialogOutputURL?.path ?? L("ui.exportDialog.destinationNotSet"))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(L("ui.exportDialog.choose")) {
                        workspace.chooseExportDialogOutputURL()
                    }
                    .disabled(workspace.isExporting)
                }

                HStack(spacing: 12) {
                    Text(L("ui.exportDialog.preset"))
                        .frame(width: 110, alignment: .leading)
                    Text(L("ui.exportDialog.presetHighestQuality"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text(L("ui.exportDialog.format"))
                        .frame(width: 110, alignment: .leading)
                    Text("MP4")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            if workspace.isExporting {
                ProgressView(value: workspace.exportProgress)
                Text(Lf("ui.toolbar.exportPercent", workspace.exportProgress * 100))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            } else if !workspace.exportStatusText.isEmpty {
                Text(workspace.exportStatusText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()

                if workspace.isExporting {
                    Button(L("ui.exportDialog.cancel")) {
                        workspace.cancelCurrentExport()
                    }
                } else {
                    Button(L("ui.exportDialog.close")) {
                        workspace.isExportDialogPresented = false
                    }

                    Button(L("ui.exportDialog.start")) {
                        workspace.startExportFromDialog()
                    }
                    .disabled(workspace.exportDialogOutputURL == nil)
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 240)
        .interactiveDismissDisabled(workspace.isExporting)
    }
}
