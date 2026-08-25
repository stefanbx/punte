#!/usr/bin/env python3
# Unit tests for the name-registrar PAID-lease verification core (pure, no live ledger). These are the
# security-critical checks that decide whether a subscription payment counts, so they are tested in
# isolation with mocked block_info. Run: python3 backend/test_paid_lease.py
import os, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("xc_common", os.path.join(HERE, "xc_common.py"))
xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)

RELAY = 'nano_1relayaccountxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
FAKE_PUB = 'AABBCC'  # what our fake nano_to_pub returns for RELAY
fake_pub = lambda acct: FAKE_PUB if acct == RELAY else 'ZZ'

def blk(**kw):
    b = {'confirmed': 'true', 'subtype': 'send', 'amount': str(xc.NAME_PRICE_RAW),
         'contents': {'link_as_account': RELAY}}
    b.update(kw); return b

def check(name, cond):
    print(('ok  ' if cond else 'FAIL') + ' ' + name)
    assert cond, name

# --- confirmed_send_raw ---
check('confirmed send via link_as_account counts',
      xc.confirmed_send_raw(blk(), RELAY, fake_pub) == xc.NAME_PRICE_RAW)
check('confirmed send via link hex counts',
      xc.confirmed_send_raw({'confirmed': 'true', 'subtype': 'send', 'amount': '5',
                             'contents': {'link': FAKE_PUB.lower()}}, RELAY, fake_pub) == 5)
check('UNCONFIRMED is rejected (fails closed)',
      xc.confirmed_send_raw(blk(confirmed='false'), RELAY, fake_pub) == 0)
check('missing confirmed field is rejected',
      xc.confirmed_send_raw({'subtype': 'send', 'amount': '5', 'contents': {'link_as_account': RELAY}}, RELAY, fake_pub) == 0)
check('a RECEIVE (wrong subtype) does not count',
      xc.confirmed_send_raw(blk(subtype='receive'), RELAY, fake_pub) == 0)
check('a send to ANOTHER account does not count',
      xc.confirmed_send_raw(blk(contents={'link_as_account': 'nano_1someoneelse'}), RELAY, fake_pub) == 0)
check('zero / negative amount does not count',
      xc.confirmed_send_raw(blk(amount='0'), RELAY, fake_pub) == 0)
check('malformed block is rejected, not crashing',
      xc.confirmed_send_raw({'garbage': True}, RELAY, fake_pub) == 0)

# --- paid_lease_canon: deterministic regardless of payment order ---
a = xc.paid_lease_canon({'label': 'shop', 'anchor': 'nano_x', 'period_start': 1, 'period_end': 2, 'payments': ['h2', 'h1']})
b = xc.paid_lease_canon({'label': 'shop', 'anchor': 'nano_x', 'period_start': 1, 'period_end': 2, 'payments': ['h1', 'h2']})
check('paid_lease_canon is order-independent in payments', a == b)
check('paid_lease_canon changes with a different anchor',
      a != xc.paid_lease_canon({'label': 'shop', 'anchor': 'nano_y', 'period_start': 1, 'period_end': 2, 'payments': ['h1', 'h2']}))

# --- subscription_seconds: time proportional to money ---
check('one price buys one period', xc.subscription_seconds(xc.NAME_PRICE_RAW) == xc.NAME_PERIOD_S)
check('double price buys two periods', xc.subscription_seconds(2 * xc.NAME_PRICE_RAW) == 2 * xc.NAME_PERIOD_S)
check('half price buys half a period', xc.subscription_seconds(xc.NAME_PRICE_RAW // 2) == xc.NAME_PERIOD_S // 2)
check('summing split payments buys the total time',
      xc.subscription_seconds(xc.NAME_PRICE_RAW // 3 * 3) >= xc.NAME_PERIOD_S - 3)

# --- paid_lease_decision: ownership / collision / dormancy / reclaim ---
GRACE = xc.NAME_GRACE_S
ALICE, BOB = 'nano_alice', 'nano_bob'
check('a fresh name is claimable', xc.paid_lease_decision(None, ALICE, 1000)[0] is True)
active = {'anchor': ALICE, 'paid_until': 2000}
check('owner may renew their own active name', xc.paid_lease_decision(active, ALICE, 1500)[0] is True)
check('ANOTHER key cannot take an active name (collision blocked)',
      xc.paid_lease_decision(active, BOB, 1500)[0] is False)
check('another key cannot take it during grace',
      xc.paid_lease_decision(active, BOB, 2000 + GRACE - 1)[0] is False)
check('the owner can still renew during grace',
      xc.paid_lease_decision(active, ALICE, 2000 + GRACE - 1)[0] is True)
check('a DORMANT name past grace is reclaimable by anyone',
      xc.paid_lease_decision(active, BOB, 2000 + GRACE + 1) == (True, 'reclaim'))

print('\nALL PAID-LEASE CORE TESTS PASSED')
