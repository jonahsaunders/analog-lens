#!/usr/bin/env python3
"""Capture all GUI surfaces with synthetic fixtures; no PDK simulation is run.

xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/capture_gui_audit.py \
    --output-dir build/gui-audit --mode large
"""
import argparse
import csv
import os
from pathlib import Path
import sys
from PIL import ImageGrab

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tests'))
import test_integration as fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--mode', choices=('normal', 'large', 'dark'), default='normal')
    args = parser.parse_args(); args.output_dir.mkdir(parents=True, exist_ok=True)
    host = fixture.Integration(); host.setUp(); c = host.c
    try:
        # Availability fixture only; captures never invoke a simulator.
        c('set','auto_execs(ngspice)',(sys.executable,))
        c('tk','scaling',1.3333333)
        if args.mode == 'dark':
            host.app.tk.eval('''ttk::style theme create AuditDark -parent clam -settings {
                ttk::style configure . -background #202024 -foreground #f4f4f5
                ttk::style configure TFrame -background #202024
                ttk::style configure TLabel -foreground #f4f4f5
                ttk::style configure Treeview -background #29292f -fieldbackground #29292f -foreground #f4f4f5
                ttk::style configure TEntry -fieldbackground #29292f -foreground #f4f4f5
                ttk::style configure TCombobox -fieldbackground #29292f -foreground #f4f4f5
            }; ttk::style theme use AuditDark''')
        else:
            c('ttk::style','theme','use','clam')
        for font in ('TkDefaultFont','TkTextFont','TkFixedFont'):
            c('font','configure',font,'-size',14 if args.mode == 'large' else 10)
        host.call('close_window');host.call('show')
        c('after','cancel',host.get('timer'));host.set('timer','')
        path=host.load_compatible()
        with path.open() as stream: rows=list(csv.DictReader(stream))
        for index,row in enumerate(rows): row['vgs_v']=str(.55+.05*(index%3))
        with path.open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
        host.set('lut_rows',host.call('parse_lut',path.read_text()))
        c('dict','set','::mock::vectors','@m.xm1.m0[gm]',.001)
        c('dict','set','::mock::vectors','v(@m.xm1.m0[vgs])',.9)
        host.call('refresh')
        host.current_metadata()
        host.call('keep_baseline');host.call('size_selected');host.call('use_device_conditions')
        host.call('workspace_preview');host.call('refresh_workspace')
        host.set('summary','DEMO ONLY · Synthetic GUI fixture')
        host.set('run_log','DEMO ONLY · No PDK simulation was run.\n'+ '\n'.join('Synthetic progress line '+str(i) for i in range(40)))
        plan=c('dict','merge',host.get('size_plan'),c('dict','create','target_gm',float(host.get('target_gm_u'))*1e-6,'target_gmid',host.get('target_gmid'),'tolerance',10,'before_values','gm .0007 gmid 12'))
        values='gm .001 gmid 20 terminal_vgs .9 terminal_vds .9 terminal_vbs 0'
        result=host.call('evaluate_targets',plan,values)
        result=c('dict','replace',result,'advice',host.call('sizing_diagnosis',plan,values,'Miss'))
        host.set('verification_result',result)
        host.set('verification_summary','DEMO ONLY · Target miss');host.call('update_verification_text');host.call('refresh_workspace')
        main_size='900x640' if args.mode == 'large' else '1380x940'
        c('wm','geometry','.analog_lens',main_size+'+0+0')

        def capture(name, window='.analog_lens'):
            c('raise',window);host.app.update()
            host.app.after(200, lambda: c('set','::audit_settled',1));c('vwait','::audit_settled')
            host.app.update()
            x,y,w,h=[int(c('winfo',key,window)) for key in ('rootx','rooty','width','height')]
            if x < 0 or y < 0 or x+w > int(c('winfo','screenwidth',window)) or y+h > int(c('winfo','screenheight',window)):
                raise RuntimeError('Capture requires a 1440×1000 display.')
            ImageGrab.grab(bbox=(x,y,x+w,y+h),xdisplay=os.environ['DISPLAY']).save(args.output_dir/(name+'.png'))
            print(name, w,h)

        for tab in ('op','lut','compare','setup','design'):
            c('.analog_lens.tabs','select','.analog_lens.tabs.'+tab);capture(tab)
        dialogs=[('preview_size','sizepreview'),('setup_dialog','onboarding'),
                 ('project_settings','project'),('verification_dialog','verification'),
                 ('characterize_dialog','characterize'),('batch_dialog','batch'),
                 ('results_dialog','results'),('data_dialog','data'),
                 ('log_dialog','log'),('check_environment','environment')]
        for proc,name in dialogs:
            host.call(proc);w='.analog_lens.'+name
            sizes={'characterize':'780x740','onboarding':'780x630','project':'720x510','verification':'760x650','sizepreview':'720x540','batch':'760x650','results':'940x560','data':'760x440','log':'840x460','environment':'760x560'}
            c('wm','geometry',w,('640x520' if args.mode == 'large' else sizes[name])+'+0+0')
            host.app.update()
            if c('winfo','exists',w+'.page.canvas'):c(w+'.page.canvas','yview','moveto',0)
            capture(name,w)
            if name == 'results':
                first=c(w+'.tree','children','')[0];c(w+'.tree','selection','set',first)
                host.call('result_details');c('wm','geometry',w+'.details','680x400+0+0')
                capture('result-details',w+'.details');c('destroy',w+'.details')
            c('destroy',w)
        host.call('characterize_dialog');w='.analog_lens.characterize';b=w+'.page.canvas.content'
        c('wm','geometry',w,'740x640+0+0');host.set('char_edit(vds)','700 µS')
        host.call('characterization_action','::analog_lens::normalized_characterization')
        capture('characterization-error',w)
        host.set('char_edit(vds)',.9);host.set('char_error',0)
        host.set('char_status','DEMO ONLY · Illustrative running state; no simulation was started.')
        host.set('char_log','DEMO ONLY · Example progress\nCharacterizing length 1 of 2…')
        host.set('char_channel','capture-only');host.call('update_characterization_ui')
        host.app.update();c(w+'.page.canvas','yview','moveto',1);capture('characterization-busy',w)
        host.set('char_channel','');host.call('update_characterization_ui')
    finally:
        host.set('char_channel','');host.tearDown()


if __name__ == '__main__':
    main()
