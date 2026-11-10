#!/usr/bin/env python3
"""Fresh-process driver for the shared test-only glyph producer, not a second renderer."""
import argparse,collections,hashlib,json,os,subprocess
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--set',required=True,choices=['menu-glass'])
parser.add_argument('--work-directory',required=True,type=Path)
parser.add_argument('--check',action='store_true')
a=parser.parse_args()
root=Path(__file__).resolve().parent.parent
work=a.work_directory.resolve();work.mkdir(parents=True,exist_ok=True)
resources=root/'Sources/BetterTileMacOS/Resources/GlyphMasks'
old=json.loads((resources/'manifest.json').read_text())
old_entries={k:v for k,v in old['entries'].items() if not k.startswith('menu-glass|')}
sha=lambda data:hashlib.sha256(data).hexdigest()
old_files={v['file']:sha((resources/v['file']).read_bytes()) for v in old_entries.values()}
producer=root/'Tests/BetterTileMacOSTests/GlyphMaskStoreTests.swift'
prefix=producer.read_text().split('@MainActor @Suite',1)[0]
(work/'producer.swift').write_text('#sourceLocation(file: '+json.dumps(str(producer))+', line: 1)\n'+prefix)
products=root/'.build/out/Products/Debug'
exe=work/'glyph-mask-process'
frameworks=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
cmd=['swiftc','-swift-version','6','-parse-as-library','-enable-testing','-DBETTERTILE_TEST_HOOKS','-Xfrontend','-load-plugin-library','-Xfrontend',str(frameworks.parents[4]/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'),'-I',str(products),'-F',str(frameworks),'-Xlinker','-rpath','-Xlinker',str(frameworks),str(work/'producer.swift'),str(root/'Tests/BetterTileMacOSTests/MenuGlassGlyphReference.swift'),str(root/'Tools/glyph-mask-process.swift'),str(products/'BetterTileMacOS.o'),str(products/'BetterTileCore.o'),'-framework','AppKit','-framework','ApplicationServices','-framework','Carbon','-framework','ColorSync','-o',str(exe)]
with (work/'compile.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
env=os.environ.copy();env['PACKAGE_RESOURCE_BUNDLE_PATH']=str(products)
all_cases={};pids=[]
for appearance in ['light','dark']:
 for process in range(5):
  out=work/(appearance+'-'+str(process))
  with (work/(appearance+'-'+str(process)+'.log')).open('w') as log:
   subprocess.run([str(exe),'samples',appearance,str(out)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
  result=json.loads((out/'samples.json').read_text());pids.append(result['pid'])
  assert len(result['records'])==82
  for case in result['records']:
   dest=all_cases.setdefault(case['key'],{'counts':collections.Counter(),'pngs':{},'rows':{}})
   assert sum(o['count'] for o in case['outputs'])==20
   for item in case['outputs']:
    data=(out/(item['sha256']+'.rgba')).read_bytes();assert sha(data)==item['sha256']
    assert item['black'] and item['peakAlpha']==255,item
    dest['counts'][data]+=item['count'];dest['pngs'][data]=(out/item['png']).read_bytes();dest['rows'][data]=item
  print('Sampled',appearance,process+1,'/5',flush=True)
assert len(set(pids))==10 and len(all_cases)==164
metadata=work/'metadata'
with (work/'metadata.log').open('w') as log:subprocess.run([str(exe),'manifest','light',str(metadata)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
manifest=json.loads((metadata/'manifest.json').read_text())
assert {k:v for k,v in manifest['entries'].items() if not k.startswith('menu-glass|')}==old_entries
if a.check:
 assert {k for k in old['entries'] if k.startswith('menu-glass|')}==set(all_cases)
 for field in ['version','platform','sources','symbolInkSizes','findings']:
  assert manifest[field]==old[field],field
new_files={};summary=[]
for key,case in sorted(all_cases.items()):
 data=sorted(case['counts'],key=lambda b:(-case['counts'][b],b))[0];item=case['rows'][data];png=case['pngs'][data]
 entry={'file':sha(png)+'.png','format':'rgba','width':item['width'],'height':item['height']}
 assert item['width']==30*float(key.split('|')[3]) and item['height']==26*float(key.split('|')[3])
 if a.check:
  actual=old['entries'][key];actual_png=(resources/actual['file']).read_bytes()
  assert actual['width']==entry['width'] and actual['height']==entry['height'] and actual['format']=='rgba'
  assert actual['file']==sha(actual_png)+'.png'
  assert any(actual_png==candidate for candidate in case['pngs'].values()),key
 else:
  manifest['entries'][key]=entry;new_files[entry['file']]=png
 summary.append({'key':key,'samples':sum(case['counts'].values()),'setSize':len(case['counts']),'modeCount':case['counts'][data],'modeRGBA':sha(data),'peakAlpha':255})
for filename,digest in old_files.items():assert sha((resources/filename).read_bytes())==digest
# Existing entry maps and PNGs are invariant; only append the new namespace.
if not a.check:
 for filename,data in new_files.items():
  path=resources/filename
  if path.exists():assert path.read_bytes()==data
  else:path.write_bytes(data)
 candidate=work/'merged-manifest.json'
 candidate.write_text(json.dumps(manifest,sort_keys=True))
 subprocess.run([str(exe),'canonical',str(candidate),str(resources)],env=env,check=True)
 referenced={v['file'] for v in manifest['entries'].values()}
 previous={v['file'] for k,v in old['entries'].items() if k.startswith('menu-glass|')}
 for filename in previous-referenced:
  assert filename not in old_files
  (resources/filename).unlink()
def modal_bytes(case):
 return sorted(case['counts'],key=lambda b:(-case['counts'][b],b))[0]
identical=True
for key,case in all_cases.items():
 if key.endswith('|light'):
  dark=all_cases[key.rsplit('|',1)[0]+'|dark']
  identical &= modal_bytes(case)==modal_bytes(dark)
report={'set':'menu-glass','freshProcessesPerAppearance':5,'callsPerCasePerProcess':20,
 'referenceCalls':16400,'cases':summary,'exact':164,'oldEntryMapsUnchanged':True,
 'oldPNGsUnchanged':len(old_files),'appearanceCoverageIdentical':identical}
(work/'result.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
print('Exact fresh-process cases: 164/164; existing PNGs unchanged:',len(old_files),flush=True)
