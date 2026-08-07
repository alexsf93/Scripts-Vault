"""
============================================================
                    ARKANOID RETRO CRT
------------------------------------------------------------
Un remake sencillo de Arkanoid en Python usando Turtle,
con estetica visual CRT (borde verde, bloques neon, power-ups
divertidos y niveles aleatorios y estructurados).
¡Rompe bloques, recoge power-ups y llega tan lejos como puedas!

------------------------------------------------------------
¿COMO JUGAR?
- Mueve la pala con ← y → (manten pulsadas para ir mas rapido)
- Rebota la bola para romper todos los bloques.
- Recoge los power-ups que caen (¡algunos ayudan y otros no!).
- Pasa de nivel al destruir todos los bloques.
- ¡La bola acelera poco a poco!
- Pulsa Q para salir en cualquier momento.

POWER-UPS:
- L: Pala larga          S: Bola lenta
- F: Bola rapida         N: Pala corta
- M: Multibola           X: Vida extra
- R: Controles invertidos
- B: Bola atraviesa bloques
- D: Pierdes una vida    ?: Efecto aleatorio

¡Ten cuidado con los power-ups malos!

------------------------------------------------------------
Nombre:   Juego - Arkanoid.py
Autor:    Alejandro Suarez (@alexsf93)
Version:  1.0
============================================================
"""

import turtle
import random

# CRT/COLORES/BLOQUES
WIDTH, HEIGHT = 800, 600
BG_COLOR = "black"
CRT_GREEN = "#39FF14"
CRT_ORANGE = "#FF8C00"
CRT_YELLOW = "#FFE761"
CRT_CYAN = "#00FFF7"
CRT_MAGENTA = "#FF44EE"
BALL_COLOR = "#FFFF33"
PADDLE_COLOR = CRT_GREEN
BORDER_COLOR = CRT_GREEN
BLOCK_COLORS = [CRT_CYAN, CRT_MAGENTA, CRT_ORANGE, CRT_YELLOW, CRT_GREEN]
POWERUP_COLORS = {
    "L": "#4AFF47", "S": "#47E7FF", "F": "#FF2222",
    "N": "#6666FF", "M": "#FFF222", "X": "#FFFFFF",
    "R": "#FF88FF", "B": "#FF8800", "D": "#B00000", "?": "#00FFAA"
}
POWERUP_LABELS = {
    "L": "L", "S": "S", "F": "F", "N": "N", "M": "M", "X": "1UP",
    "R": "R", "B": "B", "D": "D", "?": "?"
}

BLOCK_ROWS = 6
BLOCK_COLS = 12
BLOCK_W = 56
BLOCK_H = 22
BLOCK_START_Y = HEIGHT//2 - 120

PADDLE_W, PADDLE_H = 100, 20
PADDLE_SPEED = 24
PADDLE_W_MAX = 180
PADDLE_W_MIN = 54

BALL_SIZE = 18
BALL_SPEED_INIT = 7
BALL_SPEED_MAX = 17
BALL_SPEED_MIN = 3

LIVES_INIT = 3
LIVES_MAX = 5

# ===============================
# INICIALIZACION VENTANA CRT
# ===============================
wn = turtle.Screen()
wn.title("A R K A N O I D   RETRO CRT")
wn.bgcolor(BG_COLOR)
wn.setup(width=WIDTH, height=HEIGHT)
wn.tracer(0)

# --- BORDE CRT ---
border_pen = turtle.Turtle()
border_pen.hideturtle()
border_pen.pensize(6)
border_pen.color(BORDER_COLOR)
border_pen.penup()
border_pen.goto(-WIDTH//2 + 10, HEIGHT//2 - 10)
border_pen.pendown()
for _ in range(2):
    border_pen.forward(WIDTH-20)
    border_pen.right(90)
    border_pen.forward(HEIGHT-20)
    border_pen.right(90)
border_pen.penup()

scan_pen = turtle.Turtle()
scan_pen.hideturtle()
scan_pen.pensize(1)
scan_pen.color("#1a3c1a")
scan_pen.penup()
for y in range(-HEIGHT//2+20, HEIGHT//2-20, 6):
    scan_pen.goto(-WIDTH//2+15, y)
    scan_pen.pendown()
    scan_pen.forward(WIDTH-30)
    scan_pen.penup()

# --- MARCADOR Y MENSAJES ---
score = 0
lives = LIVES_INIT
level = 1

score_pen = turtle.Turtle()
score_pen.hideturtle()
score_pen.penup()
score_pen.color(CRT_GREEN)

msg_pen = turtle.Turtle()
msg_pen.hideturtle()
msg_pen.penup()
msg_pen.color(CRT_GREEN)

def update_score():
    score_pen.clear()
    score_pen.goto(-WIDTH//2 + 80, HEIGHT//2 - 60)
    score_pen.write(f"VIDAS: {lives}", align="left", font=("Courier", 22, "bold"))
    score_pen.goto(WIDTH//2 - 80, HEIGHT//2 - 60)
    score_pen.write(f"PUNTOS: {score}", align="right", font=("Courier", 22, "bold"))
    score_pen.goto(0, HEIGHT//2 - 60)
    score_pen.write(f"NIVEL: {level}", align="center", font=("Courier", 22, "bold"))

def show_message(msg, color=CRT_GREEN):
    msg_pen.clear()
    msg_pen.color(color)
    msg_pen.goto(0, 0)
    msg_pen.write(msg, align="center", font=("Courier", 34, "bold"))

def clear_message():
    msg_pen.clear()

# --- PALA ---
paddle = turtle.Turtle()
paddle.shape("square")
paddle.color(PADDLE_COLOR)
paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=PADDLE_W/20)
paddle.penup()
paddle.goto(0, -HEIGHT//2 + 50)
paddle.cur_width = PADDLE_W

paddle_dx = 0
controls_reversed = False

def move_left():
    global paddle_dx
    paddle_dx = -PADDLE_SPEED if not controls_reversed else PADDLE_SPEED

def move_right():
    global paddle_dx
    paddle_dx = PADDLE_SPEED if not controls_reversed else -PADDLE_SPEED

def stop_paddle():
    global paddle_dx
    paddle_dx = 0

def exit_game():
    wn.bye()

# --- BOLA ---
ball = turtle.Turtle()
ball.shape("circle")
ball.color(BALL_COLOR)
ball.shapesize(stretch_wid=BALL_SIZE/20, stretch_len=BALL_SIZE/20)
ball.penup()
ball.goto(0, -HEIGHT//2 + 100)
ball.dx = BALL_SPEED_INIT * random.choice([-1, 1])
ball.dy = BALL_SPEED_INIT
ball.speed_value = BALL_SPEED_INIT
ball.breakthru = False

multi_ball = None

# --- PATRONES DE NIVELES ---
def pyramid_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = [0] * cols
        for c in range(r, cols - r):
            row[c] = 1
        pattern.append(row)
    return pattern

def inverse_pyramid_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = [1] * cols
        for c in range(r):
            row[c] = 0
            row[cols - 1 - c] = 0
        pattern.append(row)
    return pattern

def frame_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = []
        for c in range(cols):
            if r in [0, rows-1] or c in [0, cols-1]:
                row.append(1)
            else:
                row.append(0)
        pattern.append(row)
    return pattern

def checker_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = []
        for c in range(cols):
            if (r + c) % 2 == 0:
                row.append(1)
            else:
                row.append(0)
        pattern.append(row)
    return pattern

def saw_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = []
        for c in range(cols):
            if (c + r*2) % 3 == 0:
                row.append(1)
            else:
                row.append(0)
        pattern.append(row)
    return pattern

def full_pattern():
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        pattern.append([1]*cols)
    return pattern

def stair_pattern():
    # Escalera ascendente
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = [0]*cols
        for c in range(r, cols):
            row[c] = 1
        pattern.append(row)
    return pattern

def v_pattern():
    # V invertida
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    mid = cols // 2
    for r in range(rows):
        row = [0]*cols
        left = max(0, mid-r)
        right = min(cols, mid+r+1)
        for c in range(left, right):
            row[c] = 1
        pattern.append(row)
    return pattern

def grid_pattern():
    # Cuadricula tipo tablero de ajedrez mas densa
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = []
        for c in range(cols):
            if (r % 2 == 0) or (c % 2 == 0):
                row.append(1)
            else:
                row.append(0)
        pattern.append(row)
    return pattern

def honeycomb_pattern():
    # Simulacion de hexagonos
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = []
        for c in range(cols):
            if (r % 2 == 0 and c % 3 != 2) or (r % 2 == 1 and c % 3 != 0):
                row.append(1)
            else:
                row.append(0)
        pattern.append(row)
    return pattern

def diamond_pattern():
    # Rombo centrado
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    mid = cols // 2
    pattern = []
    for r in range(rows):
        row = [0]*cols
        start = max(0, mid - r)
        end = min(cols, mid + r + 1)
        if r > mid:
            start = max(0, r - mid)
            end = min(cols, cols - (r - mid))
        for c in range(start, end):
            row[c] = 1
        pattern.append(row)
    return pattern

def triple_band_pattern():
    # Tres franjas horizontales
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    for r in range(rows):
        row = [0]*cols
        if r in [0, rows//2, rows-1]:
            row = [1]*cols
        pattern.append(row)
    return pattern

def arrow_pattern():
    # Flecha apuntando abajo
    rows, cols = BLOCK_ROWS, BLOCK_COLS
    pattern = []
    mid = cols // 2
    for r in range(rows):
        row = [0]*cols
        if r < rows // 2:
            for c in range(mid - r, mid + r + 1):
                if 0 <= c < cols:
                    row[c] = 1
        else:
            row[mid] = 1
        pattern.append(row)
    return pattern

# --- ACTUALIZA TU LISTA DE PATRONES ---
PATTERN_LIST = [
    pyramid_pattern, inverse_pyramid_pattern, frame_pattern,
    checker_pattern, saw_pattern, full_pattern,
    stair_pattern, v_pattern, grid_pattern,
    honeycomb_pattern, diamond_pattern,
    triple_band_pattern, arrow_pattern
]

# --- BLOQUES ---
blocks = []

def setup_blocks(randomize=True):
    global blocks
    blocks = []
    # Elige patron de nivel
    if randomize:
        pattern = random.choice(PATTERN_LIST)()
    else:
        pattern = full_pattern()
    rows = len(pattern)
    cols = len(pattern[0])
    start_x = -cols//2 * BLOCK_W + BLOCK_W//2
    y = BLOCK_START_Y
    # --- Elegimos aleatoriamente que bloques tendran power-up ---
    block_positions = []
    for r, row in enumerate(pattern):
        for c, present in enumerate(row):
            if present:
                block_positions.append((r, c))
    n_powerups = random.randint(0, min(4, len(block_positions)))
    powerup_blocks = set(random.sample(block_positions, n_powerups)) if block_positions and n_powerups > 0 else set()
    # Ahora creamos los bloques
    y = BLOCK_START_Y
    for r, row in enumerate(pattern):
        color = BLOCK_COLORS[r % len(BLOCK_COLORS)]
        for c, present in enumerate(row):
            if not present: continue
            block = turtle.Turtle()
            block.shape("square")
            block.color(color)
            block.shapesize(stretch_wid=BLOCK_H/20, stretch_len=BLOCK_W/20)
            block.penup()
            x = start_x + c*BLOCK_W
            block.goto(x, y)
            if (r, c) in powerup_blocks:
                block.has_powerup = True
                block.powerup_type = random.choices(
                    list(POWERUP_COLORS.keys()),
                    weights=[9,9,5,5,5,3,2,2,2,3], k=1
                )[0]
            else:
                block.has_powerup = False
                block.powerup_type = None
            blocks.append(block)
        y -= BLOCK_H + 4

setup_blocks(randomize=False)

# --- POWERUPS COMO LETRAS ---
powerups = []

class Powerup:
    def __init__(self, x, y, ptype):
        self.turtle = turtle.Turtle(visible=False)
        self.turtle.penup()
        self.turtle.goto(x, y)
        self.ptype = ptype
        self.active = True
        self.color = POWERUP_COLORS[ptype]
        self.label = POWERUP_LABELS[ptype]
        self.turtle.hideturtle()
        self.y = y
        self.x = x

    def fall(self):
        if not self.active:
            return
        self.y -= 7
        self.turtle.clear()
        self.turtle.goto(self.x, self.y)
        self.turtle.color(self.color)
        self.turtle.write(self.label, align="center", font=("Arial", 26, "bold"))

    def remove(self):
        self.active = False
        self.turtle.clear()
        self.turtle.hideturtle()

    def xcor(self):
        return self.x
    def ycor(self):
        return self.y

def spawn_powerup(x, y, ptype):
    powerup = Powerup(x, y, ptype)
    powerups.append(powerup)

active_effects = {}
powerup_timer = None

def activate_powerup(ptype):
    global lives, controls_reversed, multi_ball
    if ptype == "X":
        if lives < LIVES_MAX:
            lives += 1
            show_message("¡1UP!", "#FFFFFF")
            update_score()
        else:
            show_message("¡Al máximo!", "#BBBBBB")
        wn.update()
        wn.ontimer(clear_message, 1100)
        return
    if ptype == "D":
        show_message("¡Power Down!", "#B00000")
        wn.update()
        wn.ontimer(lambda: [clear_message(), lose_life()], 800)
        return

    if ptype in active_effects:
        return
    active_effects[ptype] = True

    def end_effect():
        if ptype == "L":
            paddle.cur_width = PADDLE_W
            paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=PADDLE_W/20)
        elif ptype == "N":
            paddle.cur_width = PADDLE_W
            paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=PADDLE_W/20)
        elif ptype == "S":
            ball.speed_value = BALL_SPEED_INIT
        elif ptype == "F":
            ball.speed_value = BALL_SPEED_INIT
        elif ptype == "R":
            global controls_reversed
            controls_reversed = False
        elif ptype == "B":
            ball.breakthru = False
            if multi_ball:
                multi_ball.breakthru = False
        elif ptype == "M":
            remove_multi_ball()
        active_effects.pop(ptype, None)
        clear_message()
        wn.update()

    if ptype == "L":
        paddle.cur_width = min(PADDLE_W_MAX, paddle.cur_width+60)
        paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=paddle.cur_width/20)
        show_message("¡PALA XL!", CRT_CYAN)
    elif ptype == "N":
        paddle.cur_width = max(PADDLE_W_MIN, paddle.cur_width-40)
        paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=paddle.cur_width/20)
        show_message("¡PALA MINI!", CRT_MAGENTA)
    elif ptype == "S":
        ball.speed_value = max(BALL_SPEED_MIN, ball.speed_value-3)
        show_message("¡BOLA LENTA!", CRT_YELLOW)
    elif ptype == "F":
        ball.speed_value = min(BALL_SPEED_MAX, ball.speed_value+4)
        show_message("¡BOLA RÁPIDA!", "#FF2222")
    elif ptype == "R":
        controls_reversed = True
        show_message("¡CONTROLES INVERTIDOS!", "#FF88FF")
    elif ptype == "B":
        ball.breakthru = True
        if multi_ball:
            multi_ball.breakthru = True
        show_message("¡BOLA ATRAVIESA!", "#FF8800")
    elif ptype == "M":
        spawn_multi_ball()
        show_message("¡MULTIBOLA!", CRT_YELLOW)
    elif ptype == "?":
        wn.ontimer(lambda: activate_powerup(random.choice(
            ["L","S","F","N","M","X","R","B"])), 300)
        return

    wn.update()
    powerup_timer = wn.ontimer(end_effect, 7000)

def spawn_multi_ball():
    global multi_ball
    if multi_ball: return
    multi_ball = turtle.Turtle()
    multi_ball.shape("circle")
    multi_ball.color("#FFD000")
    multi_ball.shapesize(stretch_wid=BALL_SIZE/20, stretch_len=BALL_SIZE/20)
    multi_ball.penup()
    multi_ball.goto(ball.xcor(), ball.ycor())
    multi_ball.dx = -ball.dx
    multi_ball.dy = ball.dy
    multi_ball.speed_value = ball.speed_value
    multi_ball.breakthru = ball.breakthru

def remove_multi_ball():
    global multi_ball
    if multi_ball:
        multi_ball.hideturtle()
        multi_ball = None

# --- LOGICA DEL JUEGO ---
ball_speed_counter = 0

def reset_ball_paddle(resume_game=True):
    global multi_ball, controls_reversed
    controls_reversed = False
    paddle.cur_width = PADDLE_W
    paddle.shapesize(stretch_wid=PADDLE_H/20, stretch_len=PADDLE_W/20)
    ball.breakthru = False
    remove_multi_ball()
    paddle.goto(0, -HEIGHT//2 + 50)
    ball.goto(0, -HEIGHT//2 + 100)
    ball.dx = ball.speed_value * random.choice([-1, 1])
    ball.dy = abs(ball.speed_value)
    wn.update()
    if resume_game:
        wn.ontimer(game_loop, 20)

def lose_life():
    global lives
    lives -= 1
    update_score()
    if lives > 0:
        show_message("¡Perdiste una vida!", CRT_ORANGE)
        wn.update()
        wn.ontimer(lambda: [clear_message(), reset_ball_paddle(True)], 1500)
    else:
        show_message("¡GAME OVER!", CRT_MAGENTA)
        wn.update()
        wn.ontimer(lambda: wn.bye(), 3000)

def check_win():
    if not blocks:
        show_message("¡NIVEL SUPERADO!", CRT_CYAN)
        wn.update()
        wn.ontimer(next_level, 2000)
        return True
    return False

def next_level():
    global level
    level += 1
    setup_blocks(randomize=True)
    reset_ball_paddle(resume_game=True)
    update_score()
    clear_message()
    wn.update()

def move_ball_instance(b):
    b.setx(b.xcor() + b.dx)
    b.sety(b.ycor() + b.dy)
    # Rebote lateral
    if b.xcor() > WIDTH//2 - BALL_SIZE//2 - 14:
        b.setx(WIDTH//2 - BALL_SIZE//2 - 14)
        b.dx *= -1
    if b.xcor() < -WIDTH//2 + BALL_SIZE//2 + 14:
        b.setx(-WIDTH//2 + BALL_SIZE//2 + 14)
        b.dx *= -1
    # Rebote arriba
    if b.ycor() > HEIGHT//2 - BALL_SIZE//2 - 20:
        b.sety(HEIGHT//2 - BALL_SIZE//2 - 20)
        b.dy *= -1

def ball_paddle_collision(b):
    if (b.ycor() < paddle.ycor() + PADDLE_H//2 + BALL_SIZE//2 and
        b.ycor() > paddle.ycor() and
        abs(b.xcor() - paddle.xcor()) < paddle.cur_width//2 + BALL_SIZE//2):
        b.sety(paddle.ycor() + PADDLE_H//2 + BALL_SIZE//2)
        b.dy = abs(b.dy)
        offset = (b.xcor() - paddle.xcor()) / (paddle.cur_width//2)
        b.dx = b.speed_value * offset if abs(offset) > 0.12 else b.dx

def ball_block_collision(b):
    global score
    for block in blocks[:]:
        if block.distance(b) < (BLOCK_W//2 + BALL_SIZE//2 - 6):
            if not (hasattr(b, "breakthru") and b.breakthru):
                b.dy *= -1
            bx, by = block.xcor(), block.ycor()
            if hasattr(block, "has_powerup") and block.has_powerup and block.powerup_type:
                spawn_powerup(bx, by, block.powerup_type)
            block.goto(2000, 2000)
            blocks.remove(block)
            score += 10
            update_score()
            if check_win():
                return True
            break
    return False

def game_loop():
    global score, ball_speed_counter, multi_ball

    # --- Movimiento de la pala ---
    new_x = paddle.xcor() + paddle_dx
    max_x = WIDTH//2 - paddle.cur_width//2 - 18
    if new_x < -max_x:
        new_x = -max_x
    if new_x > max_x:
        new_x = max_x
    paddle.setx(new_x)

    # --- Bola principal ---
    move_ball_instance(ball)
    ball_paddle_collision(ball)
    if ball_block_collision(ball): return

    # --- Multibola ---
    if multi_ball:
        move_ball_instance(multi_ball)
        ball_paddle_collision(multi_ball)
        # Si sale de pantalla inferior
        if multi_ball.ycor() < -HEIGHT//2 + 18:
            remove_multi_ball()
        else:
            if ball_block_collision(multi_ball): return

    # --- Velocidad progresiva ---
    ball_speed_counter += 1
    if ball_speed_counter % (60 * 10) == 0 and abs(ball.dx) < BALL_SPEED_MAX:
        signx = 1 if ball.dx >= 0 else -1
        signy = 1 if ball.dy >= 0 else -1
        ball.dx += signx*0.8
        ball.dy += signy*0.7
        ball.speed_value = min(BALL_SPEED_MAX, ball.speed_value + 1)
        show_message("¡La bola acelera!", CRT_YELLOW)
        wn.update()
        wn.ontimer(clear_message, 1100)

    # --- Bola cae (fin) ---
    if ball.ycor() < -HEIGHT//2 + 18:
        reset_ball_paddle(resume_game=False)
        lose_life()
        return

    # --- Powerups en movimiento y recogida ---
    for powerup in powerups[:]:
        if not powerup.active: continue
        powerup.fall()
        # Recogido
        if (abs(powerup.xcor()-paddle.xcor()) < paddle.cur_width//2+15 and
            abs(powerup.ycor()-paddle.ycor()) < PADDLE_H//2+18):
            activate_powerup(powerup.ptype)
            powerup.remove()
            powerups.remove(powerup)
        # Fuera de pantalla
        elif powerup.ycor() < -HEIGHT//2:
            powerup.remove()
            powerups.remove(powerup)

    wn.update()
    wn.ontimer(game_loop, 15)

# --- MENSAJE DE BIENVENIDA CON CARTEL NEGRO DELANTE ---
welcome_box = turtle.Turtle()
welcome_box.hideturtle()
welcome_box.penup()
welcome_box.speed(0)
welcome_box.color("black")
welcome_box.goto(-340, 120)
welcome_box.pendown()
welcome_box.begin_fill()
for _ in range(2):
    welcome_box.forward(680)
    welcome_box.right(90)
    welcome_box.forward(240)
    welcome_box.right(90)
welcome_box.end_fill()
welcome_box.penup()

welcome_pen = turtle.Turtle()
welcome_pen.hideturtle()
welcome_pen.penup()
welcome_pen.speed(0)
welcome_pen.color(CRT_CYAN)
welcome_pen.goto(0, 90)
welcome_pen.write("A R K A N O I D   CRT", align="center", font=("Courier", 32, "bold"))
welcome_pen.goto(0, 35)
welcome_pen.write("← y → para mover    Q para salir", align="center", font=("Courier", 22, "bold"))
welcome_pen.goto(0, -10)
welcome_pen.write("Recoge los power-ups!", align="center", font=("Courier", 22, "bold"))
welcome_pen.goto(0, -65)
welcome_pen.color(CRT_YELLOW)
welcome_pen.write("Pulsa cualquier tecla para empezar", align="center", font=("Courier", 20, "bold"))

# --- Funcion para iniciar el juego ---
def start_game_from_welcome():
    welcome_box.clear()
    welcome_pen.clear()
    clear_message()
    update_score()
    # --- Activar los controles del juego ---
    wn.onkeypress(move_left, "Left")
    wn.onkeyrelease(stop_paddle, "Left")
    wn.onkeypress(move_right, "Right")
    wn.onkeyrelease(stop_paddle, "Right")
    wn.onkeypress(exit_game, "q")
    wn.listen()
    game_loop()

def launch_on_any_key(*_):
    for key in ["space", "Left", "Right", "q", "a", "s", "d", "w", "Return", "Up", "Down"]:
        wn.onkeypress(None, key)
        wn.onkeyrelease(None, key)
    start_game_from_welcome()

for key in ["space", "Left", "Right", "q", "a", "s", "d", "w", "Return", "Up", "Down"]:
    wn.onkeypress(launch_on_any_key, key)
    wn.onkeyrelease(launch_on_any_key, key)
wn.listen()
wn.update()
wn.mainloop()
