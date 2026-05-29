import { ExceptionTrackingPlugin } from 'capacitor-3rddigital-exception-tracking';

window.testEcho = () => {
    const inputValue = document.getElementById("echoInput").value;
    ExceptionTrackingPlugin.echo({ value: inputValue })
}
