#!/usr/bin/env python3
"""Static packaging checks. This does NOT replace xcodebuild/type-checking."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def parse_pbx(text):
    text = re.sub(r'//[^\n]*|/\*.*?\*/','',text,flags=re.S)
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',text)
    index = 0
    def take(expected=None):
        nonlocal index
        if index >= len(tokens): raise ValueError('Unexpected EOF')
        token=tokens[index];index+=1
        if expected and token!=expected: raise ValueError(f'Expected {expected}, got {token}')
        return token
    def value():
        token=take()
        if token=='{':
            out={}
            while tokens[index]!='}':
                key=take();take('=');out[key]=value();take(';')
            take('}');return out
        if token=='(':
            out=[]
            while tokens[index]!=')':
                out.append(value())
                if tokens[index]==',':take(',')
                elif tokens[index]!=')':raise ValueError('Missing array comma')
            take(')');return out
        return json.loads(token) if token.startswith('"') else token
    parsed=value()
    assert index==len(tokens)
    return parsed

pbx=parse_pbx((ROOT/'ASTRA.xcodeproj/project.pbxproj').read_text())
objects=pbx['objects']; assert pbx['rootObject'] in objects
for key,obj in objects.items():
    for ref in ['mainGroup','productRefGroup','buildConfigurationList','productReference','fileRef']:
        if ref in obj: assert obj[ref] in objects, (key,ref)
    for refs in ['children','files','targets','buildPhases','buildConfigurations']:
        for ref in obj.get(refs,[]): assert ref in objects, (key,refs,ref)
    if obj['isa']=='PBXFileReference' and obj.get('sourceTree')=='SOURCE_ROOT': assert (ROOT/obj['path']).exists(), obj['path']
source_paths={o['path'] for o in objects.values() if o['isa']=='PBXFileReference' and o.get('path','').endswith(('.swift','.cpp','.mm','.metal'))}
actual_paths={p.relative_to(ROOT).as_posix() for folder in ['App','Core','UITests'] for p in (ROOT/folder).iterdir() if p.suffix in ['.swift','.cpp','.mm','.metal']}
assert source_paths==actual_paths
for path in ROOT.glob('App/*.plist'): plistlib.loads(path.read_bytes())
plistlib.loads((ROOT/'App/PrivacyInfo.xcprivacy').read_bytes())
scheme=ET.parse(ROOT/'ASTRA.xcodeproj/xcshareddata/xcschemes/ASTRA.xcscheme')
for element in scheme.findall('.//BuildableReference'): assert element.attrib['BlueprintIdentifier'] in objects
for path in ROOT.glob('App/Assets.xcassets/**/Contents.json'): json.loads(path.read_text())
pngs=list((ROOT/'Samples').glob('*.png'));assert len(pngs)==8
for path in pngs:
    data=path.read_bytes();assert data[:8]==b'\x89PNG\r\n\x1a\n';w,h,depth,typ,_,_,_=struct.unpack('>IIBBBBB',data[16:29]);assert (w,h,depth,typ)==(640,480,16,2)
assert not list(ROOT.rglob('*.ipa')), 'Unexpected IPA: native builds must be explicitly verified before packaging'
print(f'PASS package structure: {len(actual_paths)} native sources, PBX references, plists, scheme, assets, {len(pngs)} 16-bit fixtures')
print('Native Swift/Objective-C++ compilation, signing and iPhone execution remain UNVERIFIED.')
