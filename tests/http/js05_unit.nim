# JS-05: The public settings API preserves a configurable managed-send limit.
import jestersimple

let normal = newSettings()
doAssert normal.managedSendTimeoutMs == 15_000

let shortDeadline = newSettings(managedSendTimeoutMs = 400)
doAssert shortDeadline.managedSendTimeoutMs == 400

echo "JS-05 managed-send settings unit tests PASS"
