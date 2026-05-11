import algorithm, asyncdispatch, asynchttpserver, logging, parseopt, posix, strformat, strutils, zippy

const
  expVer = "1.0.0"
  nimVer = NimVersion

  DefaultMetric = ("content-type", "text/plain; version=0.0.4; charset=utf-8")
  HTMLText      = ("content-type", "text/html; charset=utf-8")
  PlainText     = ("content-type", "text/plain; charset=utf-8")
  Gzip          = ("content-encoding", "gzip")
  NoSniff       = ("x-content-type-options", "nosniff")

type
  MetricEntry = object
    name, mtype, help, value, labels, baseName: string

  SocketReader = object
    fd: SocketHandle
    buffer: array[8192, char]
    pos, len: int

var
  metricStore {.threadvar.}: seq[MetricEntry]

const IndexPage = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Unbound Exporter Lite</title></head>
<body>
  <h1>Unbound Exporter Lite """ & expVer & """</h1>
  <p><a href="/metrics">Metrics</a></p>
  <p><a href="/health">Health</a></p>
</body>
</html>
"""

# --- Signals ---
proc handleSignal(sig: cint) {.noconv.} =
  stdout.writeLine "\nINFO: Received signal " & $sig & ". Exiting cleanly..."
  flushFile(stdout)
  quit(0)

discard signal(SIGINT,  handleSignal)
discard signal(SIGTERM, handleSignal)

# --- Helpers ---
proc nextLine(sr: var SocketReader): string =
  result = ""
  while true:
    if sr.pos >= sr.len:
      sr.len = recv(sr.fd, addr(sr.buffer[0]), sr.buffer.len, 0)
      sr.pos = 0
      if sr.len <= 0: break

    let c = sr.buffer[sr.pos]
    sr.pos.inc
    if c == '\n': break
    if c != '\r': result.add(c)

proc addMetric(name, mtype, help, value: string; labels: string = ""; baseName: string = "") =
  metricStore.add(MetricEntry(name: name, mtype: mtype, help: help, value: value, labels: labels,
                              baseName: if baseName == "": name else: baseName))

proc parseListenAddress(val: string): (string, int) =
  try:
    if val.startsWith("["):
      let parts = val[1..^1].split("]:", 1)
      return (parts[0], parts[1].parseInt)
    let parts = val.rsplit(':', 1)
    let host = if parts[0] == "": "0.0.0.0" else: parts[0]
    return (host, parts[1].parseInt)
  except IndexDefect, ValueError:
    raise newException(ValueError, "Invalid address format: " & val)

# --- Metrics ---
proc getMetrics(socketPath: string): string =
  metricStore.setLen(0)
  result = newStringOfCap(16384)
  var
    bucketSeen      = false
    cumulativeCount = 0.0
    histAvg         = 0.0
    totalQueries    = 0.0

  addMetric("unbound_exporter_build_info", "gauge",
    "A metric with a constant '1' value labeled by version, and nimversion",
    "1", &"""version="{expVer}",nimversion="{nimVer}"""")

  let conn = socket(AF_UNIX, SOCK_STREAM, 0)
  if conn == SocketHandle(-1):
    raise newException(OSError, "Could not create socket handle")

  var address: SockAddr_un
  address.sun_family = AF_UNIX.uint16

  try:
    if socketPath.len > address.sun_path.high:
      raise newException(ValueError, "Socket path too long")

    copyMem(address.sun_path[0].addr, socketPath.cstring, socketPath.len)

    if connect(conn, cast[ptr SockAddr](addr address), sizeof(address).SockLen) != 0:
      raise newException(OSError, "connect failed: " & $strerror(errno))

    let msg = "UBCT1 stats_noreset\n"
    discard send(conn, msg.cstring, msg.len, 0)

    var reader = SocketReader(fd: conn)

    while true:
      let line = reader.nextLine()
      if line == "": break

      let pos = line.find('=')
      if pos == -1: continue
      let key = line[0 ..< pos]
      let val = line[pos + 1 .. ^1]

      let isThread = key.startsWith("thread")
      let tidStr   = if isThread: key.split('.')[0].replace("thread", "") else: ""
      let tlabel   = if tidStr == "": "" else: "thread=\"" & tidStr & "\""

      if key.endsWith(".num.cachehits"):
        addMetric("unbound_cache_hits_total", "counter",
          "Total number of queries that were successfully answered using a cache lookup.",
          val, tlabel, "unbound_cache_hits_total")

      elif key.endsWith(".num.cachemiss"):
        addMetric("unbound_cache_misses_total", "counter",
          "Total number of cache queries that needed recursive processing.",
          val, tlabel, "unbound_cache_misses_total")

      elif key.endsWith(".num.queries"):
        if isThread:
          addMetric("unbound_queries_total", "counter",
            "Total number of queries received.",
            val, &"""thread="{tidStr}"""", "unbound_queries_total")
        elif key == "total.num.queries":
          totalQueries = val.parseFloat()
          addMetric("unbound_queries_total", "counter",
            "Total number of queries received.",
            val, "", "unbound_queries_total")

      elif key == "total.num.expired":
        addMetric("unbound_expired_total", "counter",
          "Total number of expired entries served.", val)

      elif key.endsWith(".num.prefetch"):
        addMetric("unbound_prefetches_total", "counter",
          "Total number of cache prefetches performed.",
          val, tlabel, "unbound_prefetches_total")

      elif key.endsWith(".num.recursivereplies"):
        addMetric("unbound_recursive_replies_total", "counter",
          "Total number of replies sent to queries that needed recursive processing.",
          val, tlabel, "unbound_recursive_replies_total")

      elif key.endsWith(".num.queries_ip_ratelimited"):
        addMetric("unbound_queries_ip_ratelimited_total", "counter",
          "Total queries rate limited by IP.",
          val, tlabel, "unbound_queries_ip_ratelimited_total")

      elif key.endsWith(".num.queries_cookie_valid"):
        addMetric("unbound_queries_cookie_valid_total", "counter",
          "Total number of queries with a valid DNS cookie.",
          val, tlabel, "unbound_queries_cookie_valid_total")

      elif key.endsWith(".num.queries_cookie_client"):
        addMetric("unbound_queries_cookie_client_total", "counter",
          "Total number of queries with a client-only DNS cookie.",
          val, tlabel, "unbound_queries_cookie_client_total")

      elif key.endsWith(".num.queries_cookie_invalid"):
        addMetric("unbound_queries_cookie_invalid_total", "counter",
          "Total number of queries with an invalid DNS cookie.",
          val, tlabel, "unbound_queries_cookie_invalid_total")

      elif key.startsWith("num.answer.rcode."):
        let rcode = key.split('.')[^1]
        addMetric("unbound_answer_rcodes_total", "counter",
          "Total number of answers to queries, from cache or from recursion, by response code.",
          val, &"""rcode="{rcode}"""", "unbound_answer_rcodes_total")

      elif key == "num.answer.secure":
        addMetric("unbound_answers_secure_total", "counter",
          "Total number of answers that were secure (DNSSEC validated).", val)

      elif key == "num.answer.bogus":
        addMetric("unbound_answers_bogus", "counter",
          "Total number of answers that were bogus.", val)

      elif key == "num.rrset.bogus":
        addMetric("unbound_rrset_bogus_total", "counter",
          "Total number of rrsets marked bogus by the validator.", val)

      elif key.startsWith("num.query.type."):
        let qtype = key.split('.')[^1]
        addMetric("unbound_query_types_total", "counter",
          "Total number of queries with a given query type.",
          val, &"""type="{qtype}"""", "unbound_query_types_total")

      elif key.startsWith("num.query.class."):
        let qclass = key.split('.')[^1]
        addMetric("unbound_query_classes_total", "counter",
          "Total number of queries with a given query class.",
          val, &"""class="{qclass}"""", "unbound_query_classes_total")

      elif key.startsWith("num.query.opcode."):
        let opcode = key.split('.')[^1]
        addMetric("unbound_query_opcodes_total", "counter",
          "Total number of queries with a given query opcode.",
          val, &"""opcode="{opcode}"""", "unbound_query_opcodes_total")

      elif key.startsWith("num.query.flags."):
        let flag = key.split('.')[^1]
        addMetric("unbound_query_flags_total", "counter",
          "Total number of queries that had a given flag set in the header.",
          val, &"""flag="{flag}"""", "unbound_query_flags_total")

      elif key == "num.query.ipv6":
        addMetric("unbound_query_ipv6_total", "counter",
          "Total number of queries made using IPv6 towards the Unbound server.", val)

      elif key == "num.query.tcp":
        addMetric("unbound_query_tcp_total", "counter",
          "Total number of queries made using TCP towards the Unbound server.", val)

      elif key == "num.query.tcpout":
        addMetric("unbound_query_tcpout_total", "counter",
          "Total number of queries the Unbound server made using TCP outgoing.", val)

      elif key == "num.query.udpout":
        addMetric("unbound_query_udpout_total", "counter",
          "Total number of queries the Unbound server made using UDP outgoing.", val)

      elif key == "num.query.tls":
        addMetric("unbound_query_tls_total", "counter",
          "Total number of queries made using TLS (DoT/DoH) towards the Unbound server.", val)

      elif key == "num.query.tls.resume":
        addMetric("unbound_query_tls_resume_total", "counter",
          "Total number of queries made using TLS Resume towards the Unbound server.", val)

      elif key == "num.query.https":
        addMetric("unbound_query_https_total", "counter",
          "Total number of DoH queries made towards the Unbound server.", val)

      elif key == "num.query.edns.present":
        addMetric("unbound_query_edns_present_total", "counter",
          "Total number of queries that had an EDNS OPT record present.", val)

      elif key == "num.query.edns.DO":
        addMetric("unbound_query_edns_DO_total", "counter",
          "Total number of queries with EDNS DO (DNSSEC OK) bit set.", val)

      elif key.startsWith("num.query.aggressive."):
        let rcode = key.split('.')[^1]
        addMetric("unbound_query_aggressive_nsec", "counter",
          "Total number of queries answered using Aggressive NSEC.",
          val, &"""rcode="{rcode}"""", "unbound_query_aggressive_nsec")

      elif key.startsWith("num.rpz.action."):
        let action = key.split('.')[^1].replace("rpz-", "")
        addMetric("unbound_rpz_action_count", "counter",
          "Total number of triggered Response Policy Zone actions, by type.",
          val, &"""type="{action}"""", "unbound_rpz_action_count")

      elif key.endsWith(".requestlist.avg"):
        addMetric("unbound_request_list_avg", "gauge",
          "Average number of requests in the internal requestlist.",
          val, tlabel, "unbound_request_list_avg")

      elif key.endsWith(".requestlist.max"):
        addMetric("unbound_request_list_max", "gauge",
          "Maximum size of the internal requestlist.",
          val, tlabel, "unbound_request_list_max")

      elif key.endsWith(".requestlist.overwritten"):
        addMetric("unbound_request_list_overwritten_total", "counter",
          "Total number of requests in the request list that were overwritten by newer entries.",
          val, tlabel, "unbound_request_list_overwritten_total")

      elif key.endsWith(".requestlist.exceeded"):
        addMetric("unbound_request_list_exceeded_total", "counter",
          "Total number of queries dropped because the request list was full.",
          val, tlabel, "unbound_request_list_exceeded_total")

      elif key.endsWith(".requestlist.current.all"):
        addMetric("unbound_request_list_current_all", "gauge",
          "Current size of the request list, including internally generated queries.",
          val, tlabel, "unbound_request_list_current_all")

      elif key.endsWith(".requestlist.current.user"):
        addMetric("unbound_request_list_current_user", "gauge",
          "Current size of the request list, only counting the requests from client queries.",
          val, tlabel, "unbound_request_list_current_user")

      elif key.endsWith(".recursion.time.avg"):
        if key.startsWith("total"):
          histAvg = val.parseFloat()
        addMetric("unbound_recursion_time_seconds_avg", "gauge",
          "Average time it took to answer queries that needed recursive processing.",
          val, tlabel, "unbound_recursion_time_seconds_avg")

      elif key.endsWith(".recursion.time.median"):
        addMetric("unbound_recursion_time_seconds_median", "gauge",
          "Median time it took to answer queries that needed recursive processing.",
          val, tlabel, "unbound_recursion_time_seconds_median")

      elif key.startsWith("mem.cache."):
        let cname = key.split('.')[2]
        addMetric("unbound_memory_caches_bytes", "gauge",
          "Memory in bytes in use by caches.",
          val, &"""cache="{cname}"""", "unbound_memory_caches_bytes")

      elif key.startsWith("mem.mod."):
        let mname = key.split('.')[2]
        addMetric("unbound_memory_modules_bytes", "gauge",
          "Memory in bytes in use by modules.",
          val, &"""module="{mname}"""", "unbound_memory_modules_bytes")

      elif key == "mem.total.sbrk":
        addMetric("unbound_memory_sbrk_bytes", "gauge",
          "Memory in bytes allocated through sbrk.", val)

      elif key == "mem.streamwait":
        addMetric("unbound_memory_streamwait_bytes", "gauge",
          "Memory in bytes in use by TCP stream wait buffers.", val)

      elif key.startsWith("mem.http."):
        let buf = key.split('.')[2]
        addMetric("unbound_memory_doh_bytes", "gauge",
          "Memory used by DoH buffers, in bytes.",
          val, &"""buffer="{buf}"""", "unbound_memory_doh_bytes")

      elif key == "msg.cache.count":
        addMetric("unbound_msg_cache_count", "gauge",
          "The number of messages cached.", val)

      elif key == "rrset.cache.count":
        addMetric("unbound_rrset_cache_count", "gauge",
          "The number of rrsets cached.", val)

      elif key == "msg.cache.max_collisions":
        addMetric("unbound_msg_cache_max_collisions_total", "counter",
          "Total number of msg cache hashtable collisions.", val)

      elif key == "rrset.cache.max_collisions":
        addMetric("unbound_rrset_cache_max_collisions_total", "counter",
          "Total number of rrset cache hashtable collisions.", val)

      elif key == "unwanted.queries":
        addMetric("unbound_unwanted_queries_total", "counter",
          "Total number of queries refused or dropped due to access control settings.", val)

      elif key == "unwanted.replies":
        addMetric("unbound_unwanted_replies_total", "counter",
          "Total number of replies that were unwanted or unsolicited.", val)

      elif key == "time.now":
        addMetric("unbound_time_now_seconds", "gauge",
          "Current time in seconds since 1970.", val)

      elif key == "time.up":
        addMetric("unbound_time_up_seconds_total", "counter",
          "Uptime since server boot in seconds.", val)

      elif key == "time.elapsed":
        addMetric("unbound_time_elapsed_seconds", "counter",
          "Time since last statistics printout in seconds.", val)

      elif key.startsWith("histogram."):
        let parts = key.split(".to.")
        if parts.len == 2:
          bucketSeen = true
          cumulativeCount += val.parseFloat()
          addMetric("unbound_response_time_seconds_bucket", "histogram",
            "Query response time in seconds.",
            $cumulativeCount,
            "le=\"" & formatFloat(parts[1].parseFloat(), ffDefault, -1) & "\"",
            "unbound_response_time_seconds")

    # Histogram with +Inf, _count en _sum
    if bucketSeen:
      addMetric("unbound_response_time_seconds_bucket", "histogram",
        "Query response time in seconds.",
        $cumulativeCount, "le=\"+Inf\"", "unbound_response_time_seconds")
      addMetric("unbound_response_time_seconds_count", "histogram",
        "Query response time in seconds.",
        $cumulativeCount, "", "unbound_response_time_seconds")
      addMetric("unbound_response_time_seconds_sum", "histogram",
        "Query response time in seconds.",
        $(histAvg * cumulativeCount), "", "unbound_response_time_seconds")

    addMetric("unbound_up", "gauge",
      "Whether scraping Unbound metrics was successful.", "1")

  except:
    metricStore.setLen(0)
    addMetric("unbound_up", "gauge",
      "Whether scraping Unbound metrics was successful.", "0")
  finally:
    if conn != SocketHandle(-1):
      discard close(conn)

  # Sort and export
  metricStore.sort(proc (x, y: MetricEntry): int = cmp(x.baseName, y.baseName))
  var lastBase = ""
  for entry in metricStore:
    if entry.baseName != lastBase:
      result.add("# HELP " & entry.baseName & " " & entry.help & "\n")
      result.add("# TYPE " & entry.baseName & " " & entry.mtype & "\n")
      lastBase = entry.baseName
    result.add(entry.name)
    if entry.labels != "": result.add("{" & entry.labels & "}")
    result.add(" " & entry.value & "\n")

# --- Usage ---
proc displayUsage() =
  let usageText = fmt"""
Unbound Exporter Lite {expVer}
Usage: ./unbound_exporter [options]

Options:
  --web.listen-address=:9167                Address and port to listen on (default: 0.0.0.0:9167)
  --unbound.host=unix:///run/unbound.ctl    Path to the real host root filesystem (default: /var/run/unbound.ctl)
  --help                                    Show this help message
"""
  echo usageText
  quit(0)

# --- Server ---
proc main() {.async.} =
  const compressionLevel = BestSpeed

  let
    htmlHeaders    = newHttpHeaders([HTMLText, NoSniff])
    genericHeaders = newHttpHeaders([PlainText, NoSniff])
    gzipHeaders    = newHttpHeaders([DefaultMetric, NoSniff, Gzip])
    noGzipHeaders  = newHttpHeaders([DefaultMetric, NoSniff])

  var
    address    = "0.0.0.0"
    port       = 9167
    socketPath = "/var/run/unbound.ctl"
    p          = initOptParser()

  for kind, key, val in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "unbound.host":
        var raw = val.strip().replace("\"", "")
        if raw.startsWith("unix://"): raw = raw.replace("unix://", "")
        while raw.startsWith("//"): raw = raw[1..^1]
        socketPath = raw
      of "web.listen-address": (address, port) = parseListenAddress(val)
      else: displayUsage()
    else: displayUsage()

  if posix.access(socketPath.cstring, posix.R_OK) != 0:
    raise newException(OSError, &"Could not read from socket: {socketPath}")

  addHandler(newConsoleLogger(fmtStr = "$levelname: "))

  let server = newAsyncHttpServer()

  proc cb(req: Request) {.async.} =
    let path = req.url.path
    if path == "/health":
      await req.respond(Http200, "OK\n", genericHeaders)
    elif path == "/metrics":
      let raw = getMetrics(socketPath)
      if req.headers.hasKey("Accept-Encoding") and "gzip" in req.headers["Accept-Encoding"]:
        await req.respond(Http200, compress(raw, compressionLevel, dfGzip), gzipHeaders)
      else:
        await req.respond(Http200, raw, noGzipHeaders)
    else:
      await req.respond(Http200, IndexPage, htmlHeaders)

  info("Starting Unbound Exporter Lite ", expVer, "\n",
       "Reading metrics from socket ", socketPath, "\n",
       "Metrics available at http://", address, ":", port, "/metrics")
  await server.serve(Port(port), cb, address)

waitFor main()
