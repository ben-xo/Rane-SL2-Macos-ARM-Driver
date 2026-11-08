# envelope.py <wav> — peak level of channel 1 in 100 ms windows (float32 WAV written by chrec)
import struct, sys
d = open(sys.argv[1], 'rb').read()
nch = struct.unpack_from('<H', d, 22)[0]
sr = struct.unpack_from('<I', d, 24)[0]
n = (len(d) - 44) // (4 * nch)
x = [struct.unpack_from('<f', d, 44 + 4 * nch * i)[0] for i in range(n)]
w = sr // 10
print(' '.join('%.2f' % max(abs(v) for v in x[i:i + w]) for i in range(0, n - w + 1, w)))
