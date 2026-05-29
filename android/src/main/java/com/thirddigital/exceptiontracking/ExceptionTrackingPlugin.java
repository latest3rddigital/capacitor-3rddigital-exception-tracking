package com.thirddigital.exceptiontracking;

import com.getcapacitor.Logger;

public class ExceptionTrackingPlugin {

    public String echo(String value) {
        Logger.info("Echo", value);
        return value;
    }
}
