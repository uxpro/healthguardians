#!/usr/bin/env python3
"""End-to-end test of the website and dashboards against the REAL hg_* SQL functions on a local Postgres.

The browser's calls to Supabase are intercepted (Playwright routes) and executed with psql as the signed-in account
(request.jwt.claim.sub + role authenticated), the same way PostgREST runs them. Test accounts use a test password,
never the real demo password.

  PGHOST=... PGPORT=... E2E_DB=hg_e2e python3 website/tests/e2e.py
Needs: python playwright, Google Chrome, psql, a database with the production schema and hg_dashboards.sql applied
(website/db/run-tests.sh builds one), and a static server for website/ on http://localhost:8765/healthguardians/.
"""
import asyncio, json, os, re, subprocess, sys, time, uuid
from urllib.parse import urlparse, parse_qs
from playwright.async_api import async_playwright, expect

DB = os.environ.get('E2E_DB', 'hg_e2e')
SITE = os.environ.get('E2E_SITE', 'http://localhost:8765/healthguardians/')
SUPA = 'https://czrynqwimujjpijosqfg.supabase.co'
SHOTS = os.environ.get('E2E_SHOTS', '/tmp/e2e')
PW = 'Test-password-only-for-e2e-1!'
os.makedirs(SHOTS, exist_ok=True)

USERS = {}   # email -> uuid, filled by setup()
TOKENS = {}  # access or refresh token -> uuid
FAILS = []
OTHER = bytes.fromhex('666c75666679').decode()   # name of the other company (lower case), kept out of the repo


def psql(sql, uid=None, args=None, role='authenticated'):
    pre = ''
    if uid is not None:
        pre = f"\\o /dev/null\nselect set_config('request.jwt.claim.sub', '{uid}', false);\nset role {role};\n\\o\n"
    cmd = ['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-v', f'args={json.dumps(args or {})}']
    r = subprocess.run(cmd, input=pre + sql, capture_output=True, text=True)
    if r.returncode != 0:
        m = re.search(r'ERROR:\s+(.*)', r.stderr)
        raise RuntimeError(m.group(1).strip() if m else r.stderr.strip())
    return r.stdout.strip()


def setup():
    accounts = ['cc@hg.com', 'nc@hg.com', 'admin@hg.com', 'stranger@example.org']
    for email in accounts:
        uid = psql(f"insert into auth.users (email, raw_user_meta_data) values ('{email}', '{{}}') "
                   f"on conflict (email) do update set email = excluded.email returning id;")
        USERS[email] = uid
    print('linked:', psql('select public.hg_link_demo_accounts();'))


A = ":'args'::jsonb"
RPC = {
    'hg_whoami': 'select public.hg_whoami()::text;',
    'hg_fleet': 'select public.hg_fleet()::text;',
    'hg_event_catalogue': 'select public.hg_event_catalogue()::text;',
    'hg_feed': f"select coalesce(json_agg(f), '[]')::text from public.hg_feed(({A}->>'p_since')::timestamptz, ({A}->>'p_humanoid')::uuid, ({A}->>'p_limit')::int) f;",
    'hg_log_action': f"select public.hg_log_action({A}->>'p_action', coalesce({A}->'p_details', '{{}}'::jsonb));",
    'hg_inject_event': f"select public.hg_inject_event(({A}->>'p_humanoid')::uuid, ({A}->>'p_code')::int, {A}->>'p_note')::text;",
    'hg_update_account': f"select public.hg_update_account({A}->>'p_display_name', {A}->>'p_phone')::text;",
    'hg_audit': f"select public.hg_audit(({A}->>'p_limit')::int)::text;",
}
INSERT_EVENT = (f"insert into public.hg_events (session_id, event_type, mode, question, answer, details, client_time) "
                f"select x.session_id, x.event_type, x.mode, x.question, x.answer, coalesce(x.details, '{{}}'::jsonb), x.client_time "
                f"from jsonb_to_record({A}) as x(session_id uuid, event_type text, mode text, question text, answer text, details jsonb, client_time timestamptz);")


def token_for(uid):
    a, r = 'tok-' + uuid.uuid4().hex, 'ref-' + uuid.uuid4().hex
    TOKENS[a] = uid
    TOKENS[r] = uid
    return {'access_token': a, 'refresh_token': r, 'expires_in': 3600, 'token_type': 'bearer',
            'user': {'id': uid, 'email': next(e for e, u in USERS.items() if u == uid)}}


async def handle(route):
    req = route.request
    url = urlparse(req.url)
    path, q = url.path, parse_qs(url.query)
    body = json.loads(req.post_data) if req.post_data else {}
    auth = (req.headers.get('authorization') or '').replace('Bearer ', '')

    async def reply(status, data=None):
        await route.fulfill(status=status, content_type='application/json',
                            headers={'access-control-allow-origin': '*'},
                            body='' if data is None else json.dumps(data))

    if req.method == 'OPTIONS':
        return await route.fulfill(status=204, headers={'access-control-allow-origin': '*', 'access-control-allow-headers': '*'})
    if req.headers.get('apikey') != 'sb_publishable_5N7QYMzEKYInc0TZIWrtEQ_Y1SN4fiJ':
        return await reply(401, {'message': 'missing apikey'})
    if path == '/auth/v1/token':
        if q.get('grant_type') == ['password']:
            uid = USERS.get(body.get('email', '').lower())
            if uid and body.get('password') == PW:
                return await reply(200, token_for(uid))
            return await reply(400, {'error': 'invalid_grant', 'error_description': 'Invalid login credentials'})
        uid = TOKENS.get(body.get('refresh_token'))
        return await reply(200, token_for(uid)) if uid else await reply(400, {'error': 'invalid_grant'})
    if path == '/auth/v1/logout':
        TOKENS.pop(auth, None)
        return await reply(204)
    uid = TOKENS.get(auth)
    if not uid:
        return await reply(401, {'message': 'JWT expired'})
    if path == '/auth/v1/user':
        return await reply(200, {'id': uid, 'email': next(e for e, u in USERS.items() if u == uid), 'last_sign_in_at': '2026-11-25T08:00:00Z'})
    try:
        if path.startswith('/rest/v1/rpc/'):
            fn = path.rsplit('/', 1)[1]
            if fn not in RPC:
                return await reply(404, {'message': f'function {fn} not found'})
            out = psql(RPC[fn], uid, body)
            return await reply(200, json.loads(out) if out else None) if out else await reply(204)
        if path == '/rest/v1/hg_events' and req.method == 'POST':
            psql(INSERT_EVENT, uid, body)
            return await reply(201)
        return await reply(404, {'message': 'not found'})
    except RuntimeError as err:
        msg = str(err)
        status = 403 if ('permission denied' in msg or 'hg_access_denied' in msg or 'row-level security' in msg) else 400
        return await reply(status, {'message': msg})


def check(cond, what):
    print(('  ok   ' if cond else '  FAIL ') + what)
    if not cond:
        FAILS.append(what)


async def new_page(browser, name, width=1440):
    ctx = await browser.new_context(viewport={'width': width, 'height': 900}, accept_downloads=True)
    await ctx.route(f'{SUPA}/**', handle)
    page = await ctx.new_page()
    page.errors = []
    page.on('pageerror', lambda e: page.errors.append(str(e)))
    page.on('console', lambda m: page.errors.append(m.text) if m.type == 'error' else None)
    page.name = name
    return ctx, page


async def sign_in(page, email):
    await page.goto(SITE + 'login.html')
    await page.fill('#email', email)
    await page.fill('#password', PW)
    await page.click('#login-btn')
    await page.wait_for_url('**/dashboard.html')
    await page.wait_for_selector('.dash-main h1')


async def public_pages(browser):
    print('public pages')
    ctx, page = await new_page(browser, 'public')
    files = sorted(f[:-5] for f in os.listdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) if f.endswith('.html'))
    for name in files:
        if name in ('dashboard',):
            continue
        await page.goto(SITE + f'{name}.html')
        await page.wait_for_load_state('networkidle')
        h1 = await page.locator('main h1').count()
        check(h1 == 1, f'{name}: exactly one H1')
        title = await page.title()
        check(title.endswith('Health Guardians'), f'{name}: title "{title}"')
        text = (await page.content()).lower()
        check(OTHER not in text, f'{name}: no mention of the other company')
        for href in await page.eval_on_selector_all('a[href]', 'els => els.map(e => e.getAttribute("href"))'):
            if href.startswith(('http', 'mailto:', '#')):
                continue
            target = href.split('#')[0]
            if target and not os.path.exists(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), target)):
                check(False, f'{name}: broken link {href}')
        await page.screenshot(path=f'{SHOTS}/page_{name}.png', full_page=True)
    # cookie notice: once accepted it stays away
    await page.goto(SITE + 'index.html')
    check(await page.locator('.cookie-notice').is_visible(), 'cookie notice shown first')
    await page.click('.cookie-notice [data-ok]')
    await page.goto(SITE + 'about.html')
    check(await page.locator('.cookie-notice').count() == 0, 'cookie notice remembered')
    # accessibility widget
    await page.click('.a11y-toggle')
    await page.click('[data-scale="1.3"]')
    await page.check('[data-k="contrast"]')
    check(await page.evaluate("document.documentElement.classList.contains('a11y-contrast')"), 'high contrast on')
    await page.goto(SITE + 'faq.html')
    check(await page.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--text-scale').trim()") == '1.3', 'text size kept')
    await page.click('.a11y-toggle')
    await page.click('[data-reset]')
    # contact form demo
    await page.goto(SITE + 'contact.html')
    await page.click('#contact-form button[type=submit]')
    check('fill in' in (await page.text_content('#contact-result')), 'contact form validates')
    await page.fill('#c-name', 'Test'); await page.fill('#c-email', 'a@b.org'); await page.fill('#c-msg', 'Hello')
    await page.click('#contact-form button[type=submit]')
    check('nothing was sent' in (await page.text_content('#contact-result')), 'contact form demo message')
    # mobile menu
    await page.set_viewport_size({'width': 390, 'height': 840})
    await page.goto(SITE + 'index.html')
    await page.click('.menu-toggle')
    check(await page.locator('#main-nav').is_visible(), 'mobile menu opens')
    await page.screenshot(path=f'{SHOTS}/mobile_home.png', full_page=True)
    check(not page.errors, f'public pages: no console errors {page.errors[:3]}')
    await ctx.close()


async def login_errors(browser):
    print('sign-in errors')
    ctx, page = await new_page(browser, 'login')
    await page.goto(SITE + 'login.html')
    await page.fill('#email', 'nc@hg.com'); await page.fill('#password', 'wrong')
    await page.click('#login-btn')
    await expect(page.locator('#login-msg')).to_contain_text('not correct')
    check(True, 'wrong password rejected')
    await page.fill('#email', 'stranger@example.org'); await page.fill('#password', PW)
    await page.click('#login-btn')
    await expect(page.locator('#login-msg')).to_contain_text('no access')
    check(await page.evaluate("localStorage.getItem('hg.session')") is None, 'outsider is signed out again')
    await page.goto(SITE + 'dashboard.html')
    await page.wait_for_url('**/login.html')
    check(True, 'dashboard without session goes to sign in')
    await ctx.close()


async def north_and_admin(browser):
    print('North Clinic (live) + logistics')
    nctx, nc = await new_page(browser, 'nc')
    actx, ad = await new_page(browser, 'admin')
    await sign_in(nc, 'nc@hg.com')
    await expect(nc.locator('.dash-top .title')).to_contain_text('North Clinic dashboard')
    check('Conversation support' in await nc.text_content('.dash-main h1'), 'nc: conversation support use case')
    sel = await nc.eval_on_selector('#humanoid-select', 'e => e.selectedOptions[0].textContent')
    check(sel.startswith('Humanoid OEM B UUID ·') and 'live' in sel, f'nc: live humanoid selected ({sel})')
    check(await nc.locator('#humanoid-select option').count() == 3, 'nc: 3 humanoids in the dropdown')
    check('d1e3f5a7-9b2c-4d6e-8f0a-2c4e6a8b0d95' in await nc.text_content('.dash-main'), 'nc: linked demo patient UUID')
    check(await nc.locator('#robot-log tbody tr').count() >= 3, 'nc: seeded events in the robot log')
    check('Self test passed' in await nc.text_content('#robot-log'), 'nc: event names shown')
    # console layout: tabs, robot picture top right, plots hidden until asked, one screen without scrolling
    tabs = await nc.eval_on_selector_all('.dos-tabs [role=tab]', 'els => els.map(e => e.textContent)')
    check(tabs == ['F1Overview', 'F2Virtual face', 'F3Activity & log', 'F4Demo events'], f'nc: tabs {tabs}')
    rb = await nc.locator('.robot-box').bounding_box()
    check(rb['x'] > 1000 and rb['y'] < 200, f'nc: robot picture top right ({rb["x"]:.0f}, {rb["y"]:.0f})')
    check(await nc.locator('#plot-hour .plot-off').count() == 1 and await nc.locator('#events-chart-wrap').count() == 0, 'nc: plot hidden at first')
    await nc.click('[data-plot="hour"]')
    await nc.wait_for_selector('#events-chart-wrap svg')
    check(True, 'nc: Show plot reveals the chart')
    async def fits(page, what):
        r = await page.evaluate('''() => { const m = document.querySelector('.dash-main');
          return [document.scrollingElement.scrollHeight, innerHeight, m.scrollHeight, m.clientHeight]; }''')
        check(r[0] <= r[1] and r[2] <= r[3] + 1, f'{what}: fits the screen without scrolling {r}')
    await fits(nc, 'nc overview')
    await nc.screenshot(path=f'{SHOTS}/nc_overview.png')
    for key, view in [('F2', 'face'), ('F3', 'activity'), ('F4', 'demo')]:
        await nc.keyboard.press(key)
        await expect(nc.locator(f'.dos-tabs [data-view="{view}"]')).to_have_attribute('aria-selected', 'true')
        await fits(nc, f'nc {view}')
        await nc.screenshot(path=f'{SHOTS}/nc_{view}.png')
        if view == 'activity':
            check(await nc.locator('#events-chart-wrap svg').count() == 1, 'nc: revealed plot stays open on the activity tab')
    await nc.keyboard.press('F1')

    await sign_in(ad, 'admin@hg.com')
    await expect(ad.locator('.dash-top .title')).to_contain_text('Health Guardian Logistics Dashboard')
    groups = await ad.eval_on_selector_all('.matrix .group h3', 'els => els.map(e => e.textContent.replace(/\\s+/g, " ").trim())')
    check(groups == ['Central Clinic 4', 'North Clinic 3', 'HG warehouse and service 5'], f'admin: fleet by customer {groups}')
    check('d1e3f5a7' not in await ad.content(), 'admin never sees patient UUIDs')
    await ad.screenshot(path=f'{SHOTS}/admin_fleet.png', full_page=True)

    # check-in on the robotic face (real hg_events rows) -> North Clinic log and logistics log
    before = int(psql("select count(*) from public.hg_events;"))
    await nc.click('.dos-tabs [data-view="face"]')
    await nc.click('#start-checkin')
    await nc.wait_for_selector('[data-answer="not_good"]', timeout=15000)
    check((await nc.text_content('#face-mode')) == 'Listening', 'face listens for the answer')
    await nc.screenshot(path=f'{SHOTS}/nc_face_listening.png')
    await nc.click('[data-answer="not_good"]')
    await nc.wait_for_selector('[data-answer="no"]', timeout=15000)
    await nc.click('[data-answer="no"]')
    await expect(nc.locator('#face-mode')).to_have_text('Action', timeout=15000)
    await expect(nc.locator('#face-mode')).to_have_text('Idling', timeout=30000)
    after = int(psql("select count(*) from public.hg_events;"))
    check(after - before == 5, f'check-in wrote 5 hg_events rows ({after - before})')
    await nc.click('.dos-tabs [data-view="overview"]')
    await expect(nc.locator('#robot-log')).to_contain_text('Patient does not feel well', timeout=8000)
    await expect(nc.locator('#robot-log')).to_contain_text('Medication not taken', timeout=8000)
    check('Answer: Not good' in await nc.text_content('#robot-log'), 'nc: payload shows the answer')
    await expect(nc.locator('#incidents')).not_to_have_text('0', timeout=8000)
    check(True, f"nc: incident counter updated ({await nc.text_content('#incidents')})")

    # demo injection -> both dashboards via polling
    await nc.click('.dos-tabs [data-view="demo"]')
    await nc.fill('#inject-note', 'Bathroom')
    await nc.click('[data-inject="128"]')
    await expect(nc.locator('#robot-log')).to_contain_text('Fall detected', timeout=8000)
    check('Room: ' not in await nc.text_content('#robot-log') and 'Note: Bathroom' in await nc.text_content('#robot-log'), 'nc: injected note shown')
    await nc.click('.dos-tabs [data-view="overview"]')
    await expect(nc.locator('#event-widget')).to_contain_text('Fall detected', timeout=8000)
    t0 = time.time()
    await expect(ad.locator('#event-widget')).to_contain_text('Fall detected', timeout=12000)
    check(True, f'admin sees the injected fall after {time.time() - t0:.1f} s')
    check(await ad.locator('.toast .card').count() >= 1, 'admin: alert toast')
    # select the live humanoid on the logistics side
    await ad.click('[data-unit="b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55"]')
    await ad.wait_for_selector('#robot-log')
    log = await ad.text_content('#robot-log')
    check('Fall detected' in log and 'Bathroom' not in log and 'Not good' not in log, 'admin: gateway log without payloads')
    check('Operating time' in await ad.text_content('.dash-main aside'), 'admin: per-instance panel')
    check(int(await ad.text_content('#incidents')) >= 3, f"admin: incidents counted ({await ad.text_content('#incidents')})")
    await ad.screenshot(path=f'{SHOTS}/admin_instance.png', full_page=True)
    # OEM tab
    await ad.click('[data-tab="oem"]')
    groups = await ad.eval_on_selector_all('.matrix .group h3', 'els => els.map(e => e.textContent.replace(/\\s+/g, " ").trim())')
    check(groups == ['OEM A 4', 'OEM B 4', 'OEM C 2', 'OEM D 2'], f'admin: fleet by OEM {groups}')
    check('OEM A variant A, OEM A variant B' in await ad.text_content('.matrix'), 'admin: variants listed')
    # sub views
    await ad.click('[data-goto="parts"]')
    check(await ad.locator('table.brut tbody tr').count() == 8, 'admin: components list of the OEM')
    check('Spare Humanoid OEM B Component H' in await ad.text_content('.dash-main'), 'admin: friendly part names')
    await ad.click('[data-goto="fleet"]')
    await ad.click('[data-goto="reliability"]')
    check(await ad.locator('.chart svg').count() == 1, 'admin: reliability plot')
    await ad.screenshot(path=f'{SHOTS}/admin_reliability.png', full_page=True)
    # mock maintenance with the 4 s technician timer
    await ad.click('[data-view="maintenance"]')
    await ad.click('#mock-form button[type=submit]')
    await expect(ad.locator('#tech-status')).to_have_text('Waiting for the technician')
    await expect(ad.locator('#tech-status')).to_have_text('Technician has accepted the request', timeout=6000)
    check(True, 'maintenance request accepted after the timer')
    # warehouse
    await ad.click('[data-view="warehouse"]')
    await ad.select_option('#w-filter', 'OEM_C')
    check((await ad.text_content('#w-count')) == '8 rows', 'warehouse filter')
    check('Humanoid OEM N UUID' in await ad.text_content('#w-table'), 'warehouse lists Humanoid OEM N UUID')
    await ad.select_option('#w-filter', '')
    await ad.screenshot(path=f'{SHOTS}/admin_warehouse.png', full_page=True)
    # export without payloads
    await ad.click('[data-view="export"]')
    async with ad.expect_download() as dl:
        await ad.click('#export-form button[type=submit]')
    path = await (await dl.value).path()
    csv = open(path, encoding='utf-8-sig').read()
    check(csv.startswith('Date,Time,Humanoid') and 'Payload' not in csv and 'Fall detected' in csv, 'admin export has no payloads')
    # audit log
    await ad.click('[data-view="audit"]')
    await ad.wait_for_selector('#audit-body tr td')
    audit = await ad.text_content('#audit-body')
    for action in ['Inject event', 'Start check in', 'Sign in', 'Mock maintenance', 'Export events', 'Open view', 'Select humanoid']:
        check(action in audit, f'audit log has "{action}"')
    check('nc@hg.com' in audit and 'admin@hg.com' in audit, 'audit log names the accounts')
    await ad.screenshot(path=f'{SHOTS}/admin_audit.png', full_page=True)

    # nc cannot reach admin functions
    status = await nc.evaluate("""async () => {
      const s = JSON.parse(localStorage.getItem('hg.session'));
      const r = await fetch('https://czrynqwimujjpijosqfg.supabase.co/rest/v1/rpc/hg_audit', {method:'POST',
        headers:{apikey:'sb_publishable_5N7QYMzEKYInc0TZIWrtEQ_Y1SN4fiJ', Authorization:'Bearer '+s.access_token,'Content-Type':'application/json'}, body:'{}'});
      return r.status; }""")
    check(status == 403, f'nc gets 403 for the audit log ({status})')
    nc.errors = [x for x in nc.errors if '403' not in x]   # the probe above is expected to fail
    # customer export has payloads
    await nc.click('.dos-menu [data-view="export"]')
    async with nc.expect_download() as dl:
        await nc.click('#export-form button[type=submit]')
    csv = open(await (await dl.value).path(), encoding='utf-8-sig').read()
    check('Payload' in csv and 'Answer: Not good' in csv, 'customer export has payloads')
    # account details (the implemented form)
    await nc.click('.dos-menu [data-view="account"]')
    await nc.fill('#acc-phone', 'call me; now')
    await nc.click('#account-form button[type=submit]')
    check('digits' in await nc.text_content('#acc-msg'), 'account: invalid phone refused')
    await nc.fill('#acc-name', 'Ward 3 nurse station')
    await nc.fill('#acc-phone', '+371 2000 0000')
    await nc.click('#account-form button[type=submit]')
    await expect(nc.locator('#acc-msg')).to_have_text('Saved.')
    check(psql("select display_name from public.hg_members m join auth.users u on u.id = m.user_id where u.email = 'nc@hg.com';") == 'Ward 3 nurse station', 'account saved in the database')
    check('Ward 3 nurse station' in await nc.text_content('#who'), 'account name in the menu bar')
    await nc.screenshot(path=f'{SHOTS}/nc_account.png')
    # sign out
    await nc.click('#sign-out')
    await nc.wait_for_url('**/login.html')
    check(await nc.evaluate("localStorage.getItem('hg.session')") is None, 'sign out clears the session')
    check(psql("select count(*) from public.hg_audit_log where email = 'nc@hg.com' and action = 'sign_out';") == '1', 'sign out is in the audit log')
    check(not nc.errors, f'nc: no console errors {nc.errors[:3]}')
    check(not ad.errors, f'admin: no console errors {ad.errors[:3]}')
    await nctx.close(); await actx.close()


async def central(browser):
    print('Central Clinic (simulated)')
    ctx, cc = await new_page(browser, 'cc')
    await sign_in(cc, 'cc@hg.com')
    await expect(cc.locator('.dash-top .title')).to_contain_text('Central Clinic dashboard')
    check('Simulated events' in await cc.text_content('.dash-main'), 'cc: simulated badge')
    check('Fall detection' in await cc.text_content('.dash-main h1'), 'cc: fall detection use case')
    check(await cc.locator('#humanoid-select option').count() == 4, 'cc: 4 humanoids')
    check(await cc.locator('[data-inject]').count() == 0 and await cc.locator('#face').count() == 0, 'cc: no live controls')
    tabs = await cc.eval_on_selector_all('.dos-tabs [role=tab]', 'els => els.map(e => e.textContent)')
    check(tabs == ['F1Overview', 'F2Environment', 'F3Activity & log'], f'cc: tabs {tabs}')
    await cc.click('.dos-tabs [data-view="environment"]')
    check('Environmental data' in await cc.text_content('.dash-main') and 'Friendly reminders' in await cc.text_content('.dash-main'), 'cc: environment and reminders')
    check(await cc.locator('#plot-temp .plot-off').count() == 1, 'cc: temperature plot hidden at first')
    await cc.click('[data-plot="temp"]')
    await cc.wait_for_selector('#temp-chart-wrap svg')
    await cc.screenshot(path=f'{SHOTS}/cc_environment.png')
    await cc.click('.dos-tabs [data-view="overview"]')
    rows = await cc.locator('#robot-log tbody tr').count()
    check(rows >= 8, f'cc: simulated history in the robot log ({rows})')
    await cc.select_option('#humanoid-select', '9e3a7b5c-4f0d-4a6b-8c84-1d3a2b5e7f44')
    await cc.wait_for_selector('.led.red.on')
    check('Critical' in await cc.text_content('#overview-card'), 'cc: red integrity on Humanoid OEM D UUID')
    check('OEM D variant A' in await cc.text_content('.dash-main'), 'cc: model shown')
    await cc.screenshot(path=f'{SHOTS}/cc_overview.png')
    # a live simulated event arrives within ~16 s
    before = await cc.text_content('#event-widget')
    await cc.wait_for_function('(b) => document.querySelector("#event-widget").textContent !== b', arg=before, timeout=20000)
    check(True, 'cc: simulated live event animates the widget')
    check(psql("select count(*) from public.hg_robot_events e join public.hg_humanoids h on h.id = e.humanoid_id where h.customer_id = 'central-clinic' and e.source <> 'demo';") == '0',
          'simulated events are not stored')
    await cc.set_viewport_size({'width': 390, 'height': 840})
    await cc.screenshot(path=f'{SHOTS}/cc_mobile.png', full_page=True)
    check(not cc.errors, f'cc: no console errors {cc.errors[:3]}')
    await ctx.close()


async def main():
    setup()
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--no-sandbox'])
        await public_pages(browser)
        await login_errors(browser)
        await north_and_admin(browser)
        await central(browser)
        await browser.close()
    print(f'\n{len(FAILS)} failure(s)')
    for f in FAILS:
        print('  -', f)
    sys.exit(1 if FAILS else 0)

asyncio.run(main())
