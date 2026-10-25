#!/usr/bin/env python3
# Builds the tutorial's exercises from the finished game.
#
#   python3 exercises/build_tetris.py
#
# Chapters 3-8 are cut from chunks/lang/examples/tetris.blimp: each file
# carries the actors earlier chapters built (finished, without their tests),
# then the chapter's own actor with the tests that belong to it. Chapters 1
# and 2 are written by hand in their solutions/ directories. Then every
# solution with "# Exercise:" comments gets a stub next to it, with those
# handlers' bodies replaced by `reply :TODO`.
#
# After a change to the game, run this and then the tests:
#   for f in exercises/ch0*/solutions/*.blimp; do blimp $f --test; done
import os, re, sys, glob
HERE = os.path.dirname(os.path.abspath(__file__))
EX = HERE
GAME = os.path.join(HERE, '..', 'chunks', 'lang', 'examples', 'tetris.blimp')

# -- split the game into actors and chunks ------------------------------------
import re
SRC = open(GAME).read().split('\n')

def actors():
    out, i = {}, 0
    while i < len(SRC):
        m = re.match(r'actor (\S+) do$', SRC[i])
        if m:
            j = i + 1
            while SRC[j] != 'end': j += 1
            out[m.group(1)] = chunks(SRC[i+1:j])
            i = j
        i += 1
    return out

def chunks(body):
    # each chunk: {'kind': state|on|test|blank, 'key': ..., 'lines': [...]}
    res, pend, i = [], [], 0
    while i < len(body):
        l = body[i]
        if l.strip() == '':
            res.append({'kind': 'blank', 'key': None, 'lines': pend + [l]}); pend = []; i += 1; continue
        if re.match(r'  #', l):
            pend.append(l); i += 1; continue
        if re.match(r'  state ', l):
            j = i
            if l.rstrip().endswith('['):
                while body[j] != '  ]': j += 1
            key = re.match(r'  state (\w+)', l).group(1)
            res.append({'kind': 'state', 'key': key, 'lines': pend + body[i:j+1]}); pend = []; i = j + 1; continue
        m = re.match(r'  (on|test) (.*?) do\b', l)
        if m:
            kind = m.group(1)
            key = m.group(2)
            if re.search(r'\bend\s*$', l) and not l.rstrip().endswith(' do'):
                j = i
            else:
                j = i + 1
                while body[j] != '  end': j += 1
            res.append({'kind': kind, 'key': key, 'lines': pend + body[i:j+1]}); pend = []; i = j + 1; continue
        raise SystemExit('unparsed: ' + l)
    return res

def strip_comments(lines):
    return [l for l in lines if not re.match(r'\s*#', l)]

def actor(name, parts, exercises=None, tests=True, drop=(), drop_state=(), add_before_tests='', extra_tests='', header=None, keep_comments=True):
    """exercises: {handler key prefix: 'comment text'}; drop: handler key prefixes to leave out"""
    exercises = exercises or {}
    lines = []
    if header: lines += ['# ' + h if h else '#' for h in header.split('\n')]
    lines.append(f'actor {name} do')
    body = []
    for c in parts[name]:
        if c['kind'] == 'test':
            if tests is False: continue
            if tests is not True and c['key'].strip('"') not in tests: continue
        if c['kind'] == 'state' and c['key'] in drop_state: continue
        if c['kind'] == 'on' and any(c['key'].startswith(d) for d in drop): continue
        ls = c['lines'] if keep_comments else strip_comments(c['lines'])
        if c['kind'] == 'on':
            ex = [v for k, v in exercises.items() if c['key'] == k]
            if ex:
                ls = [l for l in ls if not re.match(r'\s*#', l)]
                ls = ['  # Exercise: ' + ex[0].split('\n')[0]] + ['  # ' + x for x in ex[0].split('\n')[1:]] + ls
        body.append((c['kind'], ls))
    # insert extra handlers before the first test, extra tests at the end
    out, placed = [], False
    for kind, ls in body:
        if kind == 'test' and not placed and add_before_tests:
            out += add_before_tests.rstrip('\n').split('\n') + ['']; placed = True
        out += ls
    if not placed and add_before_tests:
        out += [''] + add_before_tests.rstrip('\n').split('\n')
    while out and out[-1].strip() == '': out.pop()
    if extra_tests:
        out += [''] + extra_tests.rstrip('\n').split('\n')
    # collapse runs of blank lines
    clean = []
    for l in out:
        if l.strip() == '' and clean and clean[-1].strip() == '': continue
        clean.append(l)
    while clean and clean[0].strip() == '': clean.pop(0)
    return '\n'.join(lines + clean + ['end'])


A = actors()

# -- chapters 3-8 ---------------------------------------------------------------
TOP = 'actor Tetris do\n  state name: String :: "blimp tetris"\nend'
DONE = '# ---------------------------------------------------------------------\n# Finished in earlier chapters. Nothing to change here. They come first\n# because defining an actor runs its state defaults, and some of those\n# spawn one of these.'
MINE = '# ---------------------------------------------------------------------\n# This chapter. Fill in the handlers marked Exercise.'

def given(name, drop=(), drop_state=()):
    return actor(name, A, tests=False, drop=drop, drop_state=drop_state)

def write(dirname, fname, header, mine, done):
    d = os.path.join(EX, dirname, 'solutions'); os.makedirs(d, exist_ok=True)
    head = '\n'.join('# ' + l if l else '#' for l in header.strip('\n').split('\n'))
    tail = [x for x in done if x.startswith('# The game itself')]
    done = [x for x in done if not x.startswith('# The game itself')]
    parts = [head, DONE] + [p.strip('\n') for p in done] + [MINE] + [p.strip('\n') for p in mine] + [x.strip('\n') for x in tail]
    open(os.path.join(d, fname), 'w').write('\n\n'.join(parts) + '\n')

NEW_GAME_NO_SCREEN = '''# The tests build a whole game this way: every part spawned, then handed
# to the Game when it is spawned.
def new_game() -> Any do
  bag = spawn Tetris.Bag
  board = spawn Tetris.Board
  piece = spawn Tetris.Piece
  score = spawn Tetris.Score
  game = spawn Tetris.Game, bag: bag, board: board, piece: piece, score: score
  game <- :start
  game
end'''

# ---------------------------------------------------------------- ch03
write('ch03_board', '01_board.blimp', '''
Chapter 3 -- The board
Run: blimp exercises/ch03_board/01_board.blimp --test

The well is 10 columns by 20 rows. Tetris.Board keeps it as a list of 20
rows, each a list of 10 numbers: 0 is empty, 1..7 is a locked piece of
that kind. It answers the question the whole game rests on: do these
cells fit?
''', [actor('Tetris.Board', A, drop=(':load', ':reset', ':sweep'),
    tests=['starts as 20 rows of 10 zeros', 'fits inside, above the top, but not through the walls or floor', 'lock fills cells and blocks them', 'lock ignores cells above the top'],
    exercises={
    ':blocked?(x: Int, y: Int) when x < 0 or x > 9 or y > 19': 'outside the walls or below the floor is blocked.',
    ':blocked?(x: Int, y: Int) when y < 0': 'above the top is open. This game never puts a cell up\nthere, but many Tetris games spawn their pieces above the well.',
    ':blocked?(x: Int, y: Int)': 'anywhere else, blocked when the cell is not 0.',
    ':fits?(cells: List)': 'true when none of the {x, y} cells is blocked. Ask\nyourself: self <- :blocked?(x, y).',
    ':lock(cells: List, colour: Int)': 'write colour into every cell, skipping any above\nthe top. Reply :ok.',
    }, extra_tests='''  test "a piece fits where it spawns, and not through the floor" do
    board = spawn Tetris.Board
    piece = spawn Tetris.Piece
    piece <- :spawn(3)
    assert(board <- :fits?(piece <- :cells))
    assert(board <- :fits?(piece <- :cells_for(0, 18, 0)))
    refute(board <- :fits?(piece <- :cells_for(0, 19, 0)))
  end''')],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece')])

# ---------------------------------------------------------------- ch04
write('ch04_lines_and_score', '01_score.blimp', '''
Chapter 4 -- Clearing lines, keeping score
Run: blimp exercises/ch04_lines_and_score/01_score.blimp --test

A full row disappears and everything above it falls. The board does the
sweeping; a new actor, Tetris.Score, keeps the score, the line count and
the level, and says how fast the pieces should fall.
''', [actor('Tetris.Board', A,
    tests=['sweep clears full rows and adds empty rows on top', 'sweep on a clean board clears nothing, reset wipes it'],
    exercises={':sweep': 'drop every full row (no 0 in it), put that many empty\nrows on top, and reply with how many rows went.'}),
  actor('Tetris.Score', A, exercises={
    ':cleared(n: Int)': 'n rows cleared at once pay 0, 100, 300, 500 or 800,\ntimes the level. Every 10 lines is a level. Reply with the new score.',
    ':soft_drop': 'one point. Reply with the new score.',
    ':hard_drop(rows: Int)': 'two points a row. Reply with the new score.',
    ':drop_interval': 'milliseconds between gravity ticks: 800 on level 1, 70\nfewer each level, never under 120.',
  })],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece')])

# ---------------------------------------------------------------- ch05
write('ch05_bag', '01_bag.blimp', '''
Chapter 5 -- The bag
Run: blimp exercises/ch05_bag/01_bag.blimp --test

Which piece comes next? Not a dice roll: modern Tetris deals from a bag
of all seven kinds, shuffled, and refills it when it is empty. You never
wait more than twelve pieces for the one you need. Testing something
random means testing what stays true however it comes out.
''', [actor('Tetris.Bag', A, exercises={
    ':next': 'take the head of the bag, refilling it with :shuffled\nfirst if it is empty.',
    ':shuffled': 'the numbers 1..7 in a random order. random(a, b) is\nan Int from a to b inclusive.',
  }, extra_tests='''  test "not every bag comes out in the same order" do
    bag = spawn Tetris.Bag
    first = bag <- :shuffled
    others = for i in range(1, 10) do bag <- :shuffled end
    refute(empty?(filter(others, fn(s: List) do s != first end)))
  end

  test "reset throws away what is left of the bag" do
    bag = spawn Tetris.Bag
    bag <- :next
    bag <- :next
    bag <- :reset
    draws = for i in range(1, 7) do bag <- :next end
    assert_eq(sort(draws), [1, 2, 3, 4, 5, 6, 7])
  end''')],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece'), given('Tetris.Board'), given('Tetris.Score')])

GAME_CH06_TESTS = '''  test "down drops one row and scores a point" do
    game = new_game()
    assert_eq(game <- :down, :ok)
    piece = game <- :piece
    assert_eq(lookup(piece <- :info, :y), 1)
    assert_eq(lookup(game <- :summary, :score), 1)
  end

  test "rotating against the wall kicks the piece back in" do
    game = new_game()
    piece = game <- :piece
    piece <- :spawn(1)
    game <- :rotate
    for i in range(1, 6) do game <- :right end
    assert_eq(lookup(piece <- :info, :x), 7)
    assert_eq(game <- :rotate, :ok)
    info = piece <- :info
    assert_eq(lookup(info, :x), 6)
    assert_eq(lookup(info, :rot), 2)
    board = game <- :board
    assert(board <- :fits?(piece <- :cells))
  end

  test "pause freezes the piece until it is pressed again" do
    game = new_game()
    game <- :pause
    assert(game <- :paused?)
    game <- :left
    game <- :down
    piece = game <- :piece
    info = piece <- :info
    assert_eq(lookup(info, :x), 3)
    assert_eq(lookup(info, :y), 0)
    game <- :pause
    refute(game <- :paused?)
    game <- :left
    assert_eq(lookup(piece <- :info, :x), 2)
  end'''

# ---------------------------------------------------------------- ch06
write('ch06_game', '01_game.blimp', '''
Chapter 6 -- The game takes input
Run: blimp exercises/ch06_game/01_game.blimp --test

Tetris.Game is handed the bag, the board, the piece and the score when it
is spawned, and turns a player's key presses into messages to them. It
owns only three things of its own: the next kind, and whether the game is
over or paused.
''', [actor('Tetris.Game', A,
    drop=(':drop', ':tick', ':hard_drop', ':gravity', ':lock_piece', ':frame', ':view'), drop_state=('screen',),
    tests=['start spawns a piece at the top, not over, not paused', 'left and right move the piece, the walls stop it', 'rotate turns the piece'],
    exercises={
      ':start': 'reset the board, the score and the bag, spawn a piece of\nthe bag\'s next kind, and remember the kind after that. Not over, not\npaused. Reply :ok.',
      ':nudge(dx: Int, dy: Int)': 'move the piece by dx, dy if its cells there fit on the\nboard, and reply what the move replied. Otherwise reply :blocked.',
      ':soft_drop': 'nudge down one row, and score a point if it moved.\nReply what the nudge replied.',
      ':turn(dir: Int)': 'rotate the piece by dir. If it does not fit, try\nshifting it 1 left, 1 right, 2 left, 2 right, and use the first that fits\n(self <- :kick(k, dir)). None fit: reply :blocked.',
    }, extra_tests=GAME_CH06_TESTS), NEW_GAME_NO_SCREEN],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece'), given('Tetris.Board'), given('Tetris.Score'), given('Tetris.Bag')])

GAME_CH07_TESTS = '''  test "a paused game ignores the clock" do
    game = new_game()
    game <- :pause
    game <- :tick
    piece = game <- :piece
    assert_eq(lookup(piece <- :info, :y), 0)
    game <- :pause
    game <- :tick
    assert_eq(lookup(piece <- :info, :y), 1)
  end

  test "a piece that locks above the top ends the game" do
    game = new_game()
    board = game <- :board
    board <- :load(for y in range(0, 19) do
      case y do
        0 -> [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        _ -> [0, 0, 0, 0, 0, 0, 0, 1, 1, 0]
      end
    end)
    piece = game <- :piece
    piece <- :spawn(2)
    piece <- :move(3, -1)
    game <- :tick
    assert(game <- :over?)
  end

  test "dropping into a gap clears the row and scores it" do
    game = new_game()
    board = game <- :board
    gap = [1, 1, 1, 0, 0, 0, 0, 1, 1, 1]
    board <- :load(for y in range(0, 19) do
      case y do
        19 -> gap
        _ -> [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      end
    end)
    piece = game <- :piece
    piece <- :spawn(1)
    game <- :drop
    assert_eq(elem(board <- :rows, 19), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    s = game <- :summary
    assert_eq(lookup(s, :lines), 1)
    assert_eq(lookup(s, :score), 136)
  end'''

# ---------------------------------------------------------------- ch07
write('ch07_gravity', '01_gravity.blimp', '''
Chapter 7 -- Gravity, landing, game over
Run: blimp exercises/ch07_gravity/01_gravity.blimp --test

The clock sends the game :tick, and a tick is one row of gravity. A piece
that cannot fall any further locks into the board, the full rows go, the
score is paid, and the next piece spawns. If it spawns into something,
the game is over.
''', [actor('Tetris.Game', A,
    drop=(':frame', ':view'), drop_state=('screen',),
    tests=['tick drops one row, down drops one row and scores a point', 'hard drop locks the piece and spawns the next one', 'stacking to the top ends the game, restart clears it'],
    exercises={
      ':gravity': 'move the piece down a row if it fits there. If it does\nnot, it has landed: lock it. Reply what that replied.',
      ':drop_distance(dy: Int)': 'how many rows the piece can fall straight down from\ndy rows below where it is. Call it with 0.',
      ':hard_drop': 'fall all the way, pay two points a row, lock. Reply :ok.',
      ':lock_piece': 'write the piece into the board, sweep, pay for the\nrows, spawn the next kind and draw the one after it. The game is over\nif the piece locked partly above the top or the new one does not fit.\nReply :ok.',
    }, extra_tests=GAME_CH07_TESTS).replace('assert(lookup(game <- :frame, :over))', 'assert(game <- :over?)'), NEW_GAME_NO_SCREEN],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece'), given('Tetris.Board'), given('Tetris.Score'), given('Tetris.Bag')])

# ---------------------------------------------------------------- ch08
src = open(GAME).read()
tail = src[src.index('# the tests build their own game this way'):].strip('\n')
new_game_def = tail[:tail.index('spawn Tetris\n')].strip('\n')
startup = '# The game itself. The page runs this file, and the last line, game <- :view,\n# is the first screen it draws.\n' + tail[tail.index('spawn Tetris\n'):].strip('\n')
write('ch08_screen', '01_screen.blimp', '''
Chapter 8 -- The screen, and playing it
Run: blimp exercises/ch08_screen/01_screen.blimp --test

The last actor draws. Tetris.Screen gets one map describing the game and
replies with a view: a value made of heading, text, row, stack, button,
key and timer. The page renders the value and turns your key presses and
the timer back into messages to the game. Press Play when the tests pass.
''', [actor('Tetris.Screen', A, exercises={
      ':paint(grid: List, cells: List, v: Int)': 'write v into the grid at each {x, y}, skipping cells\nabove the top. Reply the new grid.',
      ':line(cells: List)': 'one row of numbers as one string of glyphs.',
      ':board_lines(frame: Map)': 'paint the ghost (8) and then the piece over the\nboard rows, and reply with 20 strings.',
      ':effects(frame: Map)': 'the keys, always, and a timer that sends :tick every\ninterval ms, only while the game is neither over nor paused.',
    }),
  actor('Tetris.Game', A,
    tests=['pause freezes gravity and movement and drops the timer', 'the view paints the piece and its ghost'],
    exercises={':frame': 'everything the screen needs, as one map: rows, piece,\nghost (the piece\'s cells dropped as far as they go), kind, next, score,\ninterval, paused, over.'}),
  new_game_def],
  [TOP, given('Tetris.Shapes'), given('Tetris.Piece'), given('Tetris.Board'), given('Tetris.Score'), given('Tetris.Bag'), startup])

# -- stubs ------------------------------------------------------------------------
for sol in sorted([f for f in glob.glob(os.path.join(EX, 'ch*', 'solutions', '*.blimp')) if '# Exercise:' in open(f).read()]):
    lines = open(sol).read().split('\n')
    out, i, n = [], 0, 0
    while i < len(lines):
        l = lines[i]
        out.append(l)
        if re.match(r'\s*# Exercise:', l):
            # copy the rest of the comment, then the handler head
            i += 1
            while re.match(r'\s*#', lines[i]):
                out.append(lines[i]); i += 1
            head = lines[i]
            ind = re.match(r'(\s*)', head).group(1)
            assert re.match(r'\s*on :', head), (sol, head)
            one = re.match(r'(\s*on .*? do)\s+.*\s+end\s*$', head)
            if one:
                out.append(one.group(1) + ' reply :TODO end')
            else:
                out.append(head)
                i += 1
                while lines[i] != ind + 'end':
                    i += 1
                out.append(ind + '  reply :TODO')
                out.append(ind + 'end')
            n += 1
        i += 1
    dest = os.path.join(os.path.dirname(os.path.dirname(sol)), os.path.basename(sol))
    open(dest, 'w').write('\n'.join(out))
    print(f'{dest}: {n} stubbed')
