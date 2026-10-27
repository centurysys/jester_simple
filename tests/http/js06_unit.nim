# JS-06: configuration compatibility and opt-in timeout customization.
import jestersimple
import jestersimple/private/httptransport as transport

# ------------------------------------------------------------------------------
# Verify documented defaults and the public settings constructor.
# ------------------------------------------------------------------------------
proc main() =
  let defaults = newSettings()
  doAssert defaults.managedSendTimeoutMs == 15000
  doAssert defaults.responseStartTimeoutMs == 15000
  doAssert defaults.streamTotalTimeoutMs == 60000

  let custom = newSettings(responseStartTimeoutMs = 350,
                           streamTotalTimeoutMs = 1200)
  doAssert custom.responseStartTimeoutMs == 350
  doAssert custom.streamTotalTimeoutMs == 1200

  discard transport.newAsyncHttpServer(responseStartTimeoutMs = 350,
    streamTotalTimeoutMs = 1200)
  doAssert transport.MaxManagedStreamChunkBytes == 64 * 1024
  echo "JS-06 settings unit tests PASS"

main()
