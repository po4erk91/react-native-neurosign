package com.neurosign

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.common.MapBuilder
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.uimanager.events.RCTEventEmitter

@ReactModule(name = SignaturePlacementViewManager.REACT_CLASS)
class SignaturePlacementViewManager : SimpleViewManager<SignaturePlacementView>() {

    companion object {
        const val REACT_CLASS = "NeurosignSignaturePlacementView"

        const val COMMAND_CONFIRM = 1
        const val COMMAND_RESET = 2
    }

    override fun getName(): String = REACT_CLASS

    override fun createViewInstance(reactContext: ThemedReactContext): SignaturePlacementView {
        val view = SignaturePlacementView(reactContext)

        view.onPlacementConfirmed = { data ->
            val event = Arguments.createMap().apply {
                putInt("pageIndex", data["pageIndex"] as Int)
                putDouble("x", data["x"] as Double)
                putDouble("y", data["y"] as Double)
                putDouble("width", data["width"] as Double)
                putDouble("height", data["height"] as Double)
            }
            val emitter = reactContext
                .getJSModule(RCTEventEmitter::class.java)
            emitter.receiveEvent(view.id, "onPlacementConfirmed", event)
        }

        view.onPageCount = { count ->
            val event = Arguments.createMap().apply {
                putInt("count", count)
            }
            val emitter = reactContext
                .getJSModule(RCTEventEmitter::class.java)
            emitter.receiveEvent(view.id, "onPageCount", event)
        }

        return view
    }

    // MARK: - Props

    @ReactProp(name = "pdfUrl")
    fun setPdfUrl(view: SignaturePlacementView, url: String?) {
        view.setPdfUrl(url)
    }

    @ReactProp(name = "signatureImageUrl")
    fun setSignatureImageUrl(view: SignaturePlacementView, url: String?) {
        view.setSignatureImageUrl(url)
    }

    @ReactProp(name = "pageIndex", defaultInt = 0)
    fun setPageIndex(view: SignaturePlacementView, index: Int) {
        view.setPageIndex(index)
    }

    @ReactProp(name = "defaultPositionX", defaultFloat = -1f)
    fun setDefaultPositionX(view: SignaturePlacementView, x: Float) {
        view.setDefaultPositionX(x)
    }

    @ReactProp(name = "defaultPositionY", defaultFloat = -1f)
    fun setDefaultPositionY(view: SignaturePlacementView, y: Float) {
        view.setDefaultPositionY(y)
    }

    @ReactProp(name = "placeholderBackgroundColor")
    fun setPlaceholderBackgroundColor(view: SignaturePlacementView, color: String?) {
        view.setPlaceholderBackgroundColor(color)
    }

    @ReactProp(name = "sigBorderColor")
    fun setSigBorderColor(view: SignaturePlacementView, color: String?) {
        view.setSigBorderColor(color)
    }

    @ReactProp(name = "sigBorderWidth", defaultFloat = 2f)
    fun setSigBorderWidth(view: SignaturePlacementView, width: Float) {
        view.setSigBorderWidth(width)
    }

    @ReactProp(name = "sigBorderPadding", defaultFloat = 0f)
    fun setSigBorderPadding(view: SignaturePlacementView, padding: Float) {
        view.setSigBorderPadding(padding)
    }

    @ReactProp(name = "sigCornerSize", defaultFloat = 14f)
    fun setSigCornerSize(view: SignaturePlacementView, size: Float) {
        view.setSigCornerSize(size)
    }

    @ReactProp(name = "sigCornerWidth", defaultFloat = 3f)
    fun setSigCornerWidth(view: SignaturePlacementView, width: Float) {
        view.setSigCornerWidth(width)
    }

    @ReactProp(name = "sigBorderRadius", defaultFloat = 0f)
    fun setSigBorderRadius(view: SignaturePlacementView, radius: Float) {
        view.setSigBorderRadius(radius)
    }

    // MARK: - Commands

    override fun getCommandsMap(): Map<String, Int> {
        return mapOf(
            "confirm" to COMMAND_CONFIRM,
            "reset" to COMMAND_RESET
        )
    }

    override fun receiveCommand(view: SignaturePlacementView, commandId: String, args: ReadableArray?) {
        when (commandId) {
            "confirm" -> view.confirm()
            "reset" -> view.reset()
        }
    }

    // MARK: - Events

    override fun getExportedCustomDirectEventTypeConstants(): Map<String, Any> {
        return MapBuilder.builder<String, Any>()
            .put("onPlacementConfirmed", MapBuilder.of("registrationName", "onPlacementConfirmed"))
            .put("onPageCount", MapBuilder.of("registrationName", "onPageCount"))
            .build()
    }
}
