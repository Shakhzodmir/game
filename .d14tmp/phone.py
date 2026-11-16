import sys
sys.path.insert(0, "tools/audio")
import soundfile as sf
import analysis as A
for p in sys.argv[1:]:
    x, sr = sf.read(p, dtype="float64")
    a = A.lufs(x, sr, circular=True)[0]
    b = A.lufs(A.phone(x, sr, circular=True), sr, circular=True)[0]
    print("%-40s lufs %6.1f phone %6.1f loss %5.1f centroid %5.0f" % (p, a, b, a - b, A.centroid(x, sr)))
