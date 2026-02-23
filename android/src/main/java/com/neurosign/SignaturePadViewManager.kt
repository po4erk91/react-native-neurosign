package com.neurosign

import android.graphics.Color
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.common.MapBuilder

@ReactModule(name = SignaturePadViewManager.REACT_CLASS)
class SignaturePadViewManager : SimpleViewManager<SignaturePadView>() {

    companion object {
        const val REACT_CLASS = "SignaturePadView"

        // Command IDs
        const val COMMAND_CLEAR = 1
        const val COMMAND_UNDO = 2
        const val COMMAND_REDO = 3
        const val COMMAND_EXPORT_SIGNATURE = 4
    }

    override fun getName(): String = REACT_CLASS

    override fun createViewInstance(reactContext: ThemedReactContext): SignaturePadView {
        val view = SignaturePadView(reactContext)

        view.onDrawingChanged = { hasDrawing ->
            val event = com.facebook.react.bridge.Arguments.createMap().apply {
                putBoolean("hasDrawing", hasDrawing)
            }
            val reactEventEmitter = reactContext
                .getJSModule(com.facebook.react.uimanager.events.RCTEventEmitter::class.java)
            reactEventEmitter.receiveEvent(view.id, "onDrawingChanged", event)
        }

        view.onSignatureExported = { imageUrl ->
            val event = com.facebook.react.bridge.Arguments.createMap().apply {
                putString("imageUrl", imageUrl)
            }
            val reactEventEmitter = reactContext
                .getJSModule(com.facebook.react.uimanager.events.RCTEventEmitter::class.java)
            reactEventEmitter.receiveEvent(view.id, "onSignatureExported", event)
        }

        return view
    }

    @ReactProp(name = "strokeColor")
    fun setStrokeColor(view: SignaturePadView, color: String?) {
        if (color != null) {
            try {
                view.strokeColor = Color.parseColor(color)
            } catch (_: Exception) { }
        }
    }

    @ReactProp(name = "strokeWidth", defaultFloat = 4f)
    fun setStrokeWidth(view: SignaturePadView, width: Float) {
        view.strokeWidth = width
    }

    @ReactProp(name = "backgroundColor")
    fun setBackgroundColor(view: SignaturePadView, color: String?) {
        if (color != null) {
            try {
                view.setBackgroundColor(Color.parseColor(color))
            } catch (_: Exception) { }
        }
    }

    @ReactProp(name = "minStrokeWidth", defaultFloat = 1f)
    fun setMinStrokeWidth(view: SignaturePadView, width: Float) {
        view.minStrokeWidth = width
    }

    @ReactProp(name = "maxStrokeWidth", defaultFloat = 10f)
    fun setMaxStrokeWidth(view: SignaturePadView, width: Float) {
        view.maxStrokeWidth = width
    }

    // MARK: - Commands

    override fun getCommandsMap(): Map<String, Int> {
        return mapOf(
            "clear" to COMMAND_CLEAR,
            "undo" to COMMAND_UNDO,
            "redo" to COMMAND_REDO,
            "exportSignature" to COMMAND_EXPORT_SIGNATURE
        )
    }

    override fun receiveCommand(view: SignaturePadView, commandId: String, args: ReadableArray?) {
        when (commandId) {
            "clear" -> view.clear()
            "undo" -> view.undo()
            "redo" -> view.redo()
            "exportSignature" -> {
                val format = args?.getString(0) ?: "png"
                val quality = args?.getInt(1) ?: 90
                view.exportSignature(format, quality)
            }
        }
    }

    // MARK: - Events

    override fun getExportedCustomDirectEventTypeConstants(): Map<String, Any> {
        return MapBuilder.builder<String, Any>()
            .put("onDrawingChanged", MapBuilder.of("registrationName", "onDrawingChanged"))
            .put("onSignatureExported", MapBuilder.of("registrationName", "onSignatureExported"))
            .build()
    }
}
