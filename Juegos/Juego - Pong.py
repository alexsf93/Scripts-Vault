"""
============================================================
                      PONG RETRO CRT
------------------------------------------------------------
Un remake del clasico juego Pong con estilo visual CRT
(ochentero, verde fosforescente y bordes de tubo), hecho en
Python usando la libreria Turtle. ¡Incluye marcador arcade,
notificaciones y controles tipo recreativa!

------------------------------------------------------------
¿COMO JUGAR?
------------------------------------------------------------
- Mueve tu pala IZQUIERDA usando las flechas ↑ y ↓
  (puedes mantenerlas pulsadas para moverte mas rapido).
- Juegas contra la CPU (pala derecha).
- El primero que falle un rebote pierde punto.
- Cada punto se notifica en pantalla, con marcador grande
  en la parte superior.
- Pulsa la tecla Q para salir del juego en cualquier momento.

------------------------------------------------------------
CARACTERISTICAS CRT/ARCADE
------------------------------------------------------------
- Efecto de bordes y lineas tipo monitor antiguo (CRT).
- Colores fosforescentes ochenteros.
- Marcador arcade, ordenado y centrado.
- Mensajes de puntuacion con "fade" al centro de pantalla.
- Movimiento fluido de palas (manteniendo flecha pulsada).
- Sin ventanas ni prompts: solo juega y disfruta.

------------------------------------------------------------
REQUISITOS
------------------------------------------------------------
- Python 3.x
- Libreria estandar `turtle` (ya incluida en Python)
- No requiere instalacion adicional.

------------------------------------------------------------
Nombre:   Juego - Pong.py
Autor:    Alejandro Suarez (@alexsf93)
Version:  1.0
============================================================
"""


import turtle
import random

# ===============================
# CONFIGURACION Y CONSTANTES CRT
# ===============================
WIDTH, HEIGHT = 800, 600
CRT_GREEN = "#39FF14"
CRT_LABEL = "#45FFDB"
BG_COLOR = "black"
BALL_COLOR = "#FFFF33"
PADDLE_COLOR = CRT_GREEN
BORDER_COLOR = CRT_GREEN

PADDLE_WIDTH, PADDLE_HEIGHT = 20, 100
BALL_SIZE = 20
BALL_SPEED = 9
PADDLE_SPEED = 10
DELAY = 16  # ms por frame (16 ms = 60 FPS)

# ===============================
# INICIALIZACION DE LA VENTANA
# ===============================
wn = turtle.Screen()
wn.title("P O N G   RETRO CRT")
wn.bgcolor(BG_COLOR)
wn.setup(width=WIDTH, height=HEIGHT)
wn.tracer(0)

# ===============================
# DIBUJAR BORDE CRT
# ===============================
border_pen = turtle.Turtle()
border_pen.hideturtle()
border_pen.pensize(6)
border_pen.color(BORDER_COLOR)
border_pen.speed(0)
border_pen.penup()
border_pen.goto(-WIDTH//2 + 10, HEIGHT//2 - 10)
border_pen.pendown()
for _ in range(2):
    border_pen.forward(WIDTH-20)
    border_pen.right(90)
    border_pen.forward(HEIGHT-20)
    border_pen.right(90)
border_pen.penup()

# CRT lineas horizontales (simular scanlines)
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

# ===============================
# MARCADOR CRT CENTRADO Y ORDENADO
# ===============================
score_a = 0
score_b = 0

# Posicion vertical extra para separar mas texto y numeros
LABEL_Y = HEIGHT//2 - 65
SCORE_Y = HEIGHT//2 - 140  # antes -110, ahora mas separado

score_label = turtle.Turtle()
score_label.hideturtle()
score_label.penup()
score_label.color(CRT_LABEL)
score_label.goto(-80, LABEL_Y)
score_label.write("JUGADOR", align="center", font=("Courier", 23, "bold"))
score_label.goto(80, LABEL_Y)
score_label.write("CPU", align="center", font=("Courier", 23, "bold"))

score_pen = turtle.Turtle()
score_pen.hideturtle()
score_pen.penup()
score_pen.color(CRT_GREEN)

def draw_score():
    score_pen.clear()
    # Puntaje Jugador
    score_pen.goto(-80, SCORE_Y)
    score_pen.write(f"{score_a}", align="center", font=("Courier", 46, "bold"))
    # Puntaje CPU
    score_pen.goto(80, SCORE_Y)
    score_pen.write(f"{score_b}", align="center", font=("Courier", 46, "bold"))

# ===============================
# TEXTO MENSAJES
# ===============================
msg_pen = turtle.Turtle()
msg_pen.hideturtle()
msg_pen.penup()
msg_pen.color(CRT_GREEN)

def show_message_fade(msg):
    fade_colors = [
        "#39FF14", "#39CC11", "#399A0D", "#336C0A", "#274C08", "#193105",
        "#102103", "#091602", "#060F01", "#030800", "#000400", "#000000"
    ]
    FADE_STEPS = len(fade_colors)
    FADE_TIME = 2000 # ms total
    def fade_step(step):
        msg_pen.clear()
        if step < FADE_STEPS:
            msg_pen.color(fade_colors[step])
            msg_pen.goto(0, -40)
            msg_pen.write(msg, align="center", font=("Courier", 28, "bold"))
            wn.update()
            wn.ontimer(lambda: fade_step(step + 1), FADE_TIME // FADE_STEPS)
        else:
            msg_pen.clear()
    fade_step(0)

def clear_message():
    msg_pen.clear()

# ===============================
# PALAS Y BOLA
# ===============================
paddle_a = turtle.Turtle()
paddle_a.shape("square")
paddle_a.color(PADDLE_COLOR)
paddle_a.shapesize(stretch_wid=PADDLE_HEIGHT/20, stretch_len=PADDLE_WIDTH/20)
paddle_a.penup()
paddle_a.goto(-WIDTH//2+40, 0)

paddle_b = turtle.Turtle()
paddle_b.shape("square")
paddle_b.color(CRT_GREEN)
paddle_b.shapesize(stretch_wid=PADDLE_HEIGHT/20, stretch_len=PADDLE_WIDTH/20)
paddle_b.penup()
paddle_b.goto(WIDTH//2-40, 0)

ball = turtle.Turtle()
ball.shape("circle")
ball.color(BALL_COLOR)
ball.shapesize(stretch_wid=BALL_SIZE/20, stretch_len=BALL_SIZE/20)
ball.penup()
ball.goto(0, 0)
ball.dx = BALL_SPEED * random.choice([-1, 1])
ball.dy = BALL_SPEED * random.choice([-1, 1])

# ===============================
# MOVIMIENTO FLUIDO DE PALAS
# ===============================
move_up = False
move_down = False
game_started = False

def start_move_up():
    global move_up
    move_up = True
    if not game_started:
        start_game()

def stop_move_up():
    global move_up
    move_up = False

def start_move_down():
    global move_down
    move_down = True
    if not game_started:
        start_game()

def stop_move_down():
    global move_down
    move_down = False

def exit_game():
    wn.bye()

wn.listen()
wn.onkeypress(start_move_up, "Up")
wn.onkeyrelease(stop_move_up, "Up")
wn.onkeypress(start_move_down, "Down")
wn.onkeyrelease(stop_move_down, "Down")
wn.onkeypress(exit_game, "q")

# ===============================
# INICIO Y LOGICA PRINCIPAL DEL JUEGO CRT
# ===============================
def reset_ball(direction=None):
    ball.goto(0, 0)
    ball.dx = BALL_SPEED * (direction if direction else random.choice([-1, 1]))
    ball.dy = BALL_SPEED * random.choice([-1, 1])

def start_game():
    global game_started
    if not game_started:
        game_started = True
        clear_message()
        draw_score()
        game_loop()

def game_loop():
    global score_a, score_b

    # --- Movimiento fluido de la pala del jugador ---
    if move_up and paddle_a.ycor() < HEIGHT//2 - PADDLE_HEIGHT/2 - 20:
        paddle_a.sety(paddle_a.ycor() + PADDLE_SPEED)
    if move_down and paddle_a.ycor() > -HEIGHT//2 + PADDLE_HEIGHT//2 + 20:
        paddle_a.sety(paddle_a.ycor() - PADDLE_SPEED)

    # --- Bola ---
    ball.setx(ball.xcor() + ball.dx)
    ball.sety(ball.ycor() + ball.dy)

    # Rebote arriba/abajo
    if ball.ycor() > HEIGHT//2 - BALL_SIZE//2 - 16:
        ball.sety(HEIGHT//2 - BALL_SIZE//2 - 16)
        ball.dy *= -1
    if ball.ycor() < -HEIGHT//2 + BALL_SIZE//2 + 16:
        ball.sety(-HEIGHT//2 + BALL_SIZE//2 + 16)
        ball.dy *= -1

    # Rebote pala izquierda (jugador)
    if (ball.xcor() < -WIDTH//2+60 and
        paddle_a.ycor() - PADDLE_HEIGHT/2 < ball.ycor() < paddle_a.ycor() + PADDLE_HEIGHT/2):
        ball.setx(-WIDTH//2+60)
        ball.dx *= -1.05

    # Rebote pala derecha (CPU)
    if (ball.xcor() > WIDTH//2-60 and
        paddle_b.ycor() - PADDLE_HEIGHT/2 < ball.ycor() < paddle_b.ycor() + PADDLE_HEIGHT/2):
        ball.setx(WIDTH//2-60)
        ball.dx *= -1.05

    # Punto para CPU
    if ball.xcor() < -WIDTH//2:
        score_b += 1
        draw_score()
        show_message_fade("¡Punto CPU!")
        reset_ball(direction=1)

    # Punto para jugador
    if ball.xcor() > WIDTH//2:
        score_a += 1
        draw_score()
        show_message_fade("¡Punto para TI!")
        reset_ball(direction=-1)

    # CPU sigue la bola (AI simple, pero fluida)
    if paddle_b.ycor() < ball.ycor() and paddle_b.ycor() < HEIGHT//2 - PADDLE_HEIGHT/2 - 20:
        paddle_b.sety(paddle_b.ycor() + PADDLE_SPEED * 0.92)
    elif paddle_b.ycor() > ball.ycor() and paddle_b.ycor() > -HEIGHT//2 + PADDLE_HEIGHT//2 + 20:
        paddle_b.sety(paddle_b.ycor() - PADDLE_SPEED * 0.92)

    wn.update()
    wn.ontimer(game_loop, DELAY)

# --- INICIO ---
msg_pen.goto(0, 0)
msg_pen.color(CRT_GREEN)
msg_pen.write("P O N G\n\n¡Mantén pulsado ↑ o ↓!\nPulsa Q para salir.",
              align="center", font=("Courier", 26, "bold"))
wn.update()

wn.mainloop()
