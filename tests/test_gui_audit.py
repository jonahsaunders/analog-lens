"""HIG follow-up: real Tk accessibility and short-window regression checks."""
import os
import unittest
import test_integration as fixture

W = '.analog_lens'


@unittest.skipUnless(os.environ.get('DISPLAY'), 'GUI audit requires X11')
class GUIAudit(unittest.TestCase):
    setUp = fixture.Integration.setUp
    tearDown = fixture.Integration.tearDown
    call = fixture.Integration.call
    get = fixture.Integration.get
    set = fixture.Integration.set
    load_compatible = fixture.Integration.load_compatible
    current_metadata = fixture.Integration.current_metadata

    def settle(self):
        self.app.update_idletasks(); self.app.update()

    def test_short_large_text_dialogs_keep_every_action_accessible(self):
        for font in ('TkDefaultFont', 'TkTextFont', 'TkFixedFont'):
            self.c('font', 'configure', font, '-size', 14)
        self.call('configure_styles'); self.load_compatible()
        cases = [('characterize_dialog', 'characterize', ('run','cancel','batch','close')),
                 ('batch_dialog', 'batch', ('run','cancel','save','load','close')),
                 ('setup_dialog', 'onboarding', ('recheck','save','run','close')),
                 ('project_settings', 'project', ('apply','cancel')),
                 ('preview_size', 'sizepreview', ('apply','run','native','cancel')),
                 ('verification_dialog', 'verification', ('compare','close')),
                 ('results_dialog', 'results', ('open','details','batch','close'))]
        for proc, name, actions in cases:
            with self.subTest(dialog=name):
                self.call(proc); w=W+'.'+name
                self.c('wm','geometry',w,'640x520+0+0'); self.c('raise',w); self.settle()
                left,top,width,height=[int(self.c('winfo',q,w)) for q in ('rootx','rooty','width','height')]
                for action in actions:
                    button=w+'.actions.'+action
                    self.assertTrue(self.c('winfo','ismapped',button))
                    x,y,bw,bh=[int(self.c('winfo',q,button)) for q in ('rootx','rooty','width','height')]
                    self.assertGreaterEqual(x,left);self.assertGreaterEqual(y,top)
                    self.assertLessEqual(x+bw,left+width);self.assertLessEqual(y+bh,top+height)
                    self.assertGreaterEqual(bw,int(self.c('winfo','reqwidth',button)))
                self.call('close_dialog',w)

    def test_keyboard_error_focus_scrolls_form_without_changing_sizing_help(self):
        self.call('characterize_dialog'); w=W+'.characterize'; b=w+'.page.canvas.content'
        self.c('wm','geometry',w,'580x440');self.settle()
        self.set('field_help','Sizing help stays here')
        self.c('focus','-force',b+'.form.fields.step');self.settle()
        self.call('page_focus',w+'.page.canvas',(b,),b+'.form.fields.step');self.settle()
        self.assertEqual(self.get('field_help'),'Sizing help stays here')
        self.assertIn('step',self.get('char_help'))
        self.set('char_edit(vds)','700 µS')
        self.call('characterization_action','::analog_lens::normalized_characterization');self.settle()
        field=b+'.form.fields.vds';self.assertEqual(str(self.c('focus')),field)
        self.assertTrue(self.c(field,'instate','invalid'))
        canvas=w+'.page.canvas'; y=int(self.c('winfo','rooty',field));top=int(self.c('winfo','rooty',canvas))
        self.assertGreaterEqual(y,top);self.assertLessEqual(y+int(self.c('winfo','height',field)),top+int(self.c('winfo','height',canvas)))
        self.assertIn('vds:',self.get('char_status'))
        self.c('event','generate',field,'<Control-w>');self.settle()
        self.assertFalse(self.c('winfo','exists',w));self.assertTrue(self.c('winfo','exists',W))

    def test_busy_batch_locks_requests_and_preserves_log_reading_position(self):
        self.call('batch_dialog');w=W+'.batch';b=w+'.page.canvas.content'
        self.set('char_log','\n'.join('Log line '+str(i) for i in range(100)))
        self.call('update_characterization_ui');self.settle()
        self.c(b+'.log','yview','moveto',.2)
        before=float(self.c(b+'.log','yview')[0])
        self.set('char_channel','fixture-running')
        try:
            self.call('update_characterization_ui');self.settle()
            for button in ('run','save','load'):
                self.assertTrue(self.c(w+'.actions.'+button,'instate','disabled'))
            self.assertTrue(self.c(b+'.form.fields.temps','instate','disabled'))
            self.assertFalse(self.c(w+'.actions.cancel','instate','disabled'))
            self.assertAlmostEqual(float(self.c(b+'.log','yview')[0]),before,places=2)
            self.assertTrue(self.c('winfo','manager',b+'.progress'))
        finally:
            self.set('char_channel','');self.call('update_characterization_ui')
        self.assertFalse(self.c('winfo','manager',b+'.progress'))

    def test_result_selection_survives_refresh_and_empty_actions_disable(self):
        self.call('keep_baseline');self.call('results_dialog');w=W+'.results'
        first=self.c(w+'.tree','children','')[0]
        self.c(w+'.tree','selection','set',first);self.settle()
        self.assertFalse(self.c(w+'.actions.details','instate','disabled'))
        self.call('refresh_results');self.assertEqual(len(self.c(w+'.tree','selection')),1)
        self.call('result_details');self.settle()
        self.assertTrue(self.c('winfo','ismapped',w+'.details.scroll'))
        self.assertTrue(self.c('winfo','ismapped',w+'.details.actions.close'))
        self.set('results_query','no-match');self.call('refresh_results');self.settle()
        self.assertIn('Clear the search',self.get('results_status'))
        self.assertTrue(self.c(w+'.actions.open','instate','disabled'))
        self.assertTrue(self.c(w+'.actions.details','instate','disabled'))

    def test_verification_disclosure_syncs_and_table_can_scroll(self):
        self.call('verification_dialog');w=W+'.verification.page.canvas.content.view'
        other=W+'.tabs.design.body.canvas.content.verify'
        self.set('workspace_details',1);self.call('verification_details',w);self.settle()
        for view in (w,other):self.assertEqual(str(self.c('winfo','manager',view+'.details')),'pack')
        self.set('workspace_details',0);self.call('verification_details',other);self.settle()
        for view in (w,other):self.assertFalse(self.c('winfo','manager',view+'.details'))
        self.assertTrue(self.c(w+'.table','cget','-xscrollcommand'))
        height=int(self.c('ttk::style','lookup','AL.Treeview','-rowheight'))
        self.assertGreater(height,int(self.c('font','metrics','ALBody','-linespace')))

    def test_mixed_host_surfaces_keep_local_text_and_focus_contrast(self):
        self.c('ttk::style','configure','TFrame','-background','#888888')
        self.c('ttk::style','configure','TLabel','-foreground','#888888')
        self.c('ttk::style','configure','Treeview','-background','#111111')
        original=self.c('ttk::style','lookup','TLabel','-foreground')
        self.call('configure_styles');colors=self.get('colors')
        for foreground,background,minimum in [('fg','bg',4.5),('muted','bg',4.5),('field_fg','field',4.5),('field_error','field',4.5),('border','field',3)]:
            a,b=[float(self.call('luminance',self.c('dict','get',colors,key))) for key in (foreground,background)]
            self.assertGreaterEqual((max(a,b)+.05)/(min(a,b)+.05),minimum)
        self.assertEqual(original,self.c('ttk::style','lookup','TLabel','-foreground'))
        self.call('close_window');self.call('show')
        self.c('wm','geometry',W,'1380x940');self.settle()
        self.assertEqual(len(self.c('pack','slaves',W+'.root.tools')),1)
