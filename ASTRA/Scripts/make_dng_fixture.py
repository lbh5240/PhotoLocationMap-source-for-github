"""Generate a small, uncompressed Bayer DNG for the native RAW decoder test."""
from pathlib import Path
import struct

width=64
height=64
entries=[]
def tag(identifier,kind,count,value):
    entries.append((identifier,kind,count,value))
u16=lambda *v:struct.pack('<'+'H'*len(v),*v)
u32=lambda *v:struct.pack('<'+'I'*len(v),*v)
rat=lambda values:b''.join(struct.pack('<ii',int(v*10000),10000) for v in values)
tag(256,4,1,u32(width));tag(257,4,1,u32(height));tag(258,3,1,u16(16));tag(259,3,1,u16(1))
tag(262,3,1,u16(32803));tag(273,4,1,u32(0));tag(277,3,1,u16(1));tag(278,4,1,u32(height));tag(279,4,1,u32(width*height*2))
tag(33421,3,2,u16(2,2));tag(33422,1,4,bytes([0,1,1,2]))
tag(50706,1,4,bytes([1,4,0,0]));tag(50707,1,4,bytes([1,1,0,0]))
name=b'ASTRA Synthetic DNG\0';tag(50708,2,len(name),name)
tag(50714,4,1,u32(512));tag(50717,4,1,u32(65535))
tag(50721,10,9,rat([1,0,0,0,1,0,0,0,1]));tag(50728,5,3,rat([1,1,1]));tag(50778,3,1,u16(21))
entries.sort();offset=8+2+12*len(entries)+4;extra=bytearray();records=[]
for identifier,kind,count,data in entries:
    if len(data)<=4:value=data.ljust(4,b'\0')
    else:
        if (offset+len(extra))%2:extra.append(0)
        value=u32(offset+len(extra));extra.extend(data)
    records.append([identifier,kind,count,value])
image_offset=offset+len(extra)
for record in records:
    if record[0]==273:record[3]=u32(image_offset)
header=b'II'+u16(42)+u32(8)+u16(len(records))
header+=b''.join(u16(i,k)+u32(n)+value for i,k,n,value in records)+u32(0)+extra
pixels=b''.join(u16(3000+(x+y)*100) for y in range(height) for x in range(width))
path=Path(__file__).resolve().parents[1]/'Android/app/src/androidTest/assets/synthetic.dng'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(header+pixels)
print(path)
