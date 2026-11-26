# Builds Casita/Media/cities.tsv from GeoNames' cities1000.txt
# (https://download.geonames.org/export/dump/cities1000.zip, CC BY 4.0):
#   python3 -I Support/make-cities.py cities1000.txt Casita/Media/cities.tsv
# Keeps populated places only, without parts of cities and historical,
# abandoned or destroyed places. Each row: name, country code, latitude,
# longitude (3 decimals, about 100 m), population.
import sys
src, out = sys.argv[1], sys.argv[2]
drop = {'PPLX', 'PPLH', 'PPLQ', 'PPLW', 'PPLCH'}
with open(out, 'w', encoding='utf-8') as f:
    for line in open(src, encoding='utf-8'):
        c = line.rstrip('\n').split('\t')
        name = c[1].replace('\t', ' ').strip()
        if c[6] != 'P' or c[7] in drop or not name or len(c[8]) != 2:
            continue
        f.write(f"{name}\t{c[8]}\t{round(float(c[4]), 3):g}\t{round(float(c[5]), 3):g}\t{int(c[14] or 0)}\n")
