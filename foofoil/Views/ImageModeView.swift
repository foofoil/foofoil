//
//  ImageModeView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

struct ImageModeView: View {
    @ObservedObject var appState: AppState
    let nsImage: NSImage
    let shouldHideBorder: Bool

    var body: some View {
        Group {
            if shouldHideBorder && !appState.isFullScreen {
                // 窗口态无边框按受约束的窗口比例铺满；全屏复用下方可滚动的内容缩放。
                renderImage(
                    for: nsImage,
                    contentMode: .fill,
                    width: nil,
                    height: nil
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // 无边框图片铺满窗口：整块画面即拖拽区域，双击缩放等父级手势仍可识别。
                    .gesture(WindowDragGesture())
            } else {
                let layoutSize = AudioMetadataLoader.layoutSize(nsImage) ?? nsImage.size
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        renderImage(
                            for: nsImage,
                            contentMode: .fit,
                            width: layoutSize.width * CGFloat(appState.imageScale),
                            height: layoutSize.height * CGFloat(appState.imageScale)
                        )
                        // Office 快速预览固定边框：按代码箔的圆角裁切，避免文档内容以直角贴到玻璃边框内。
                        .cornerRadius((appState.isQuickLookDocument && !appState.supportsBorderToggle) ? 8 : 0)
                        // 图片小于视口时始终居中；超过视口后沿两轴滚动。
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height
                        )
                        .background {
                            ImagePanGesture(
                                imageSize: NSSize(
                                    width: layoutSize.width * CGFloat(appState.imageScale),
                                    height: layoutSize.height * CGFloat(appState.imageScale)
                                ),
                                allowsPanning: appState.isFullScreen
                            )
                        }
                        .transaction { $0.animation = nil }
                    }
                }
                .padding(appState.isFullScreen ? 0 : 8) // 移至 ScrollView 外部，确保在滚动时边框始终保持同样粗细（12 像素）。
            }
        }
        .onAppear {
            // "提取文字"与"提取图片主体"都要等 Vision 给出结论才可用；ContentView 按图片路径打 id，切图会再次触发。
            if let imageURL = appState.imageURL {
                appState.detectImageTextIfNeeded(for: imageURL)
                appState.detectImageSubjectIfNeeded(for: imageURL)
            }
        }
    }

    @ViewBuilder
    private func renderImage(for nsImage: NSImage, contentMode: ContentMode, width: CGFloat?, height: CGFloat?) -> some View {
        let baseImage = Image(nsImage: nsImage).resizable()

        if appState.isSVG, let url = appState.imageURL {
            SVGImageView(url: url, contentMode: contentMode, colorHex: appState.svgColor, preparedData: appState.agentSVGData)
                .frame(width: width, height: height)
        } else if appState.isSVG, let svgColorHex = appState.svgColor, let color = Color(hex: svgColorHex) {
            baseImage
                .renderingMode(.template)
                .aspectRatio(contentMode: contentMode)
                .foregroundColor(color)
                .frame(width: width, height: height)
        } else {
            baseImage
                .aspectRatio(contentMode: contentMode)
                .frame(width: width, height: height)
        }
    }
}
