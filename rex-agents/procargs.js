// Exact argv of processes, read with sysctl(KERN_PROCARGS2) through the JavaScript for Automation
// ObjC bridge, because Rex's Lua has no FFI and `ps` joins arguments with spaces.
//
//   osascript -l JavaScript procargs.js [--env NAME]... PID...
//   -> {"PID": {"argv": [...], "env": {"NAME": "value"}}}
//
// Only the environment variables named with --env are returned; the rest of the environment is
// never printed. A PID that can't be read (gone, not ours) is left out.
ObjC.import('Foundation');
ObjC.bindFunction('sysctl', ['int', ['void *', 'unsigned int', 'void *', 'void *', 'void *', 'unsigned long']]);

function le(n, bytes) {
  var s = '';
  for (var i = 0; i < bytes; i++) { s += String.fromCharCode(n & 255); n = Math.floor(n / 256); }
  return s;
}
function latin1ToData(s) { return $(s).dataUsingEncoding($.NSISOLatin1StringEncoding); }
function dataToLatin1(d) { return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d, $.NSISOLatin1StringEncoding)); }
function utf8(s) { return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(latin1ToData(s), $.NSUTF8StringEncoding)) || s; }
function mutable(bin) { return $.NSMutableData.dataWithData(latin1ToData(bin)); }

function read(pid, envNames) {
  var cap = 1 << 20;
  var mib = mutable(le(1, 4) + le(49, 4) + le(pid, 4)); // CTL_KERN, KERN_PROCARGS2, pid
  var buf = $.NSMutableData.dataWithLength(cap);
  var size = mutable(le(cap, 8));
  if ($.sysctl(mib.mutableBytes, 3, buf.mutableBytes, size.mutableBytes, null, 0) !== 0) return null;
  var sb = dataToLatin1(size), n = 0;
  for (var i = 7; i >= 0; i--) n = n * 256 + sb.charCodeAt(i);
  var raw = dataToLatin1(buf).substring(0, n);
  var argc = raw.charCodeAt(0) + raw.charCodeAt(1) * 256 + raw.charCodeAt(2) * 65536 + raw.charCodeAt(3) * 16777216;
  var rest = raw.substring(4), k = rest.indexOf('\0');      // skip the exec path
  while (k >= 0 && k < rest.length && rest.charAt(k) === '\0') k++; // and its padding
  var parts = rest.substring(k).split('\0');
  var out = { argv: parts.slice(0, argc).map(utf8), env: {} };
  for (var j = argc; j < parts.length && parts[j] !== ''; j++) {
    var eq = parts[j].indexOf('=');
    if (eq > 0 && envNames.indexOf(parts[j].substring(0, eq)) >= 0) out.env[parts[j].substring(0, eq)] = utf8(parts[j].substring(eq + 1));
  }
  return out;
}

function run(argv) {
  var envNames = [], pids = [], out = {};
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] === '--env') envNames.push(argv[++i]);
    else pids.push(parseInt(argv[i], 10));
  }
  pids.forEach(function (pid) {
    if (!(pid > 0)) return;
    var r = read(pid, envNames);
    if (r) out[pid] = r;
  });
  return JSON.stringify(out);
}
