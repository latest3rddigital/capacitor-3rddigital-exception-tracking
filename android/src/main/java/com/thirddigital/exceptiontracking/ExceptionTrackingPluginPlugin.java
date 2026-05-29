package com.thirddigital.exceptiontracking;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "NativeExceptionHandler")
public class ExceptionTrackingPluginPlugin extends Plugin {

    private final ExceptionTrackingPlugin implementation = new ExceptionTrackingPlugin();

    @Override
    public void load() {
        implementation.attach(getContext(), this);
    }

    @PluginMethod
    public void configure(PluginCall call) {
        try {
            implementation.configure(getContext(), this, call.getData());
            call.resolve();
        } catch (Exception exception) {
            call.reject("Failed to configure native exception handler", exception);
        }
    }

    @PluginMethod
    public void releaseExceptionHold(PluginCall call) {
        boolean handled = call.getBoolean("handled", true);
        implementation.releaseExceptionHold(handled);
        call.resolve();
    }

    @PluginMethod
    public void uploadPendingException(PluginCall call) {
        boolean uploaded = implementation.uploadPendingException(getContext());
        JSObject ret = new JSObject();
        ret.put("uploaded", uploaded);
        call.resolve(ret);
    }

    @PluginMethod
    public void crashForTesting(PluginCall call) {
        String message = call.getString("message", "Test native exception from Capacitor");
        implementation.crashForTesting(message);
        call.resolve();
    }

    void emitNativeException(JSObject event) {
        notifyListeners("nativeException", event, true);
    }
}
