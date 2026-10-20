#!/usr/bin/env python3
"""Isolated hardware logic checks; no physical device or host input dispatch."""
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
def main():
    run_id=uuid.uuid4().hex[:10]
    build=ROOT/'.build/hardware-v39'/('checks-'+run_id)
    evidence=ROOT/'evidence/hardware-v39'/('checks-'+run_id)
    build.mkdir(parents=True);evidence.mkdir(parents=True)
    app=ROOT/'Sources/Vibekey'
    suites={
        'core_checks':[], 'workflow_checks':[], 'session_checks':[], 'hardware_core_checks':[], 'hardware_tracking_mode_checks':[],
        'radial_knob_checks':[], 'shortcut_capture_checks':[],
        'shortcut_recorder_checks':[app/'Support/ShortcutRecorder.swift',app/'Support/VibekeyTheme.swift',app/'Stores/WorkflowStore.swift'],
        'hardware_workflow_activation_checks':[app/'Stores/WorkflowStore.swift'],
        'device_store_session_checks':[app/'Stores/DeviceStore.swift'],
        'original_device_delivery_checks':[app/'Stores/AU05OriginalActions.swift'],
        'au05_input_configuration_checks':[app/'Stores/AU05OriginalActions.swift'],
        'au05_onboard_checks':[],
        'au05_onboard_store_checks':[app/'Stores/DeviceStore.swift',app/'Stores/AU05OnboardStore.swift'],
        'automatic_configuration_checks':[app/'Stores/WorkflowStore.swift',app/'Stores/RadialMenuStore.swift'],
        'radial_menu_checks':[], 'radial_scroll_checks':[],
        'smart_lighting_checks':[app/'Stores/SmartLightingController.swift'],
        'lighting_adapter_checks':[app/'Stores/DeviceStore.swift'],
        'agent_signal_checks':[app/'Stores/AgentSignalStore.swift'],
        'agent_signal_cache_checks':[app/'Stores/AgentSignalStore.swift'],
        'radial_integration_checks':[app/'Stores/WindowOverviewController.swift',app/'Stores/RadialMenuStore.swift',app/'Stores/RadialMenuController.swift',app/'Stores/AU05OriginalActions.swift',app/'Views/RadialMenuOverlay.swift',app/'Views/RadialWheelDiagram.swift',app/'Support/RadialScrollSelection.swift',app/'Support/VibekeyTheme.swift',app/'Support/VibekeyComponents.swift'],
    }
    core=sorted((ROOT/'Sources/VibekeyCore').glob('*.swift'))
    inputs=sorted(set(core+[p for paths in suites.values() for p in paths]+[ROOT/'tools'/(s+'.swift') for s in suites]))
    hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before=hashes()
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    common=['swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-macosx13.3','-module-cache-path',str(build/'module-cache')]
    result=subprocess.run(common+['-enable-testing','-emit-library','-static','-emit-module','-module-name','VibekeyCore',*map(str,core),'-o',str(build/'libVibekeyCore.a'),'-emit-module-path',str(build/'VibekeyCore.swiftmodule')],capture_output=True,text=True,timeout=120)
    (evidence/'core-compile.log').write_text(result.stdout+result.stderr)
    if result.returncode:print(result.stderr);return 1
    rows=[]
    for name,extra in suites.items():
        source=ROOT/'tools'/(name+'.swift');binary=build/name
        flags=['-parse-as-library'] if '@main' in source.read_text() else []
        result=subprocess.run(common+flags+['-I',str(build),'-L',str(build),'-lVibekeyCore',*map(str,extra),str(source),'-o',str(binary)],capture_output=True,text=True,timeout=120)
        (evidence/(name+'-compile.log')).write_text(result.stdout+result.stderr)
        if result.returncode:
            rows.append({'suite':name,'status':'COMPILE_FAILED'});print(name,result.stderr[-2600:],flush=True);continue
        args=[]
        if name=='workflow_checks':args=['--evidence',str(evidence/(name+'.json'))]
        if name=='radial_menu_checks':args=['--output',str(evidence/(name+'.json'))]
        if name=='agent_signal_checks':args=['--directory='+str(build/'agent-fixtures')]
        if name=='agent_signal_cache_checks':
            private=ROOT/'.build/ux-v36/cache'/('hardware-'+run_id)/'private-fixtures';private.mkdir(parents=True,mode=0o700)
            args=['--directory='+str(private)]
        if name=='radial_integration_checks':
            private=Path.home()/'Library/Caches/Vibekey/OwnedProbes'/('radial-v32-hardware-'+run_id);private.mkdir(parents=True,mode=0o700)
            args=['--ui-probe','--probe-directory='+str(private),'--report='+str(evidence/(name+'.json'))]
        result=subprocess.run([str(binary),*args],capture_output=True,text=True,timeout=90)
        (evidence/(name+'.log')).write_text(result.stdout+result.stderr)
        if result.stdout.lstrip().startswith('{'):
            try:(evidence/(name+'.json')).write_text(json.dumps(json.loads(result.stdout),indent=2))
            except json.JSONDecodeError:pass
        row={'suite':name,'status':'PASS' if result.returncode==0 else 'FAIL','exitCode':result.returncode};rows.append(row);print(json.dumps(row),flush=True)
        if result.returncode:print(result.stdout[-2200:]+result.stderr[-1200:],flush=True)
    after=hashes();drift=[p for p in before if before[p]!=after[p]]
    report={'status':'PASS' if all(r['status']=='PASS' for r in rows) and not drift else 'FAIL','suites':rows,'sourceHashesBefore':before,'sourceHashesAfter':after,'sourceDrift':drift,'physicalDeviceWrites':0,'systemInputPosted':0}
    (evidence/'receipt.json').write_text(json.dumps(report,indent=2));print(json.dumps({'status':report['status'],'evidence':str(evidence)}))
    return 0 if report['status']=='PASS' else 1
if __name__=='__main__':raise SystemExit(main())
