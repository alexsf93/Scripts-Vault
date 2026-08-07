"""
===============================================
        S N A K E  RETRO CRT  -  TURTLE
===============================================

Este script implementa una versión retro del clásico juego Snake usando la librería Turtle de Python,
emulando el efecto de una pantalla CRT (colores neón y borde fosforescente).

------------------------------------------------
Características principales:
------------------------------------------------
- Área de juego enmarcada en color verde neón.
- Snake con cabeza brillante y cuerpo verde.
- Fruta normal (roja) y fruta especial amarilla que otorga una vida extra.
- Sistema de puntuación y vidas, con hasta 5 vidas máximas.
- Texto de puntuación y vidas al estilo retro en la parte superior.
- Animaciones y ASCII art del título.
- Dificultad incremental: el snake se acelera cada vez que comes una fruta.
- Game Over con contador de reinicio automático.

------------------------------------------------
Controles:
------------------------------------------------
- Flechas del teclado (arriba, abajo, izquierda, derecha) para mover la serpiente.

------------------------------------------------
Notas:
------------------------------------------------
- Si la serpiente colisiona con un muro o su propio cuerpo, pierdes una vida y parte de la puntuación.
- La fruta amarilla aparece aleatoriamente y otorga una vida extra si no tienes el máximo.
- Cuando pierdes todas las vidas, el juego muestra "Game Over" y reinicia tras unos segundos.

------------------------------------------------
Requisitos:
------------------------------------------------
- Python 3.x
- Módulo turtle (generalmente viene preinstalado en Python estándar)

------------------------------------------------
Nombre:   Juego - Snake.py
Autor:    Alejandro Suárez (@alexsf93)
Versión:  1.0
===============================================
"""


import turtle
import random

# ---- CONFIGURACIÓN CRT ----
BG_COLOR = "black"
HEAD_COLOR = "#39FF14"
BODY_COLOR = "#00D700"
FOOD_COLOR = "#FF3131"
YELLOW_COLOR = "#FFFF33"
SCORE_COLOR = "#39FF14"

START_DELAY = 120
MIN_DELAY = 40
delay = START_DELAY

score = 0
lives = 3
MAX_LIVES = 5
game_state = "game"
segments = []

# Área jugable (más baja para no pisar encabezados)
GAME_LEFT = -180
GAME_RIGHT = 180
GAME_TOP = 80     # suficiente margen debajo de los textos
GAME_BOTTOM = -180

# --- Yellow food (vidas extra) ---
yellow_food = turtle.Turtle()
yellow_food.shape("square")
yellow_food.color(YELLOW_COLOR)
yellow_food.penup()
yellow_food.hideturtle()
yellow_food_active = False
yellow_food_timer = None
YELLOW_LIFETIME = 5000  # ms

wn = turtle.Screen()
wn.title("S N A K E  RETRO CRT")
wn.bgcolor(BG_COLOR)
wn.setup(width=600, height=600)
wn.tracer(0)

# --- Dibuja el borde del área jugable ---
border = turtle.Turtle()
border.hideturtle()
border.penup()
border.pensize(4)
border.color("#39FF14")
border.goto(GAME_LEFT, GAME_TOP)
border.pendown()
for _ in range(2):
    border.forward(GAME_RIGHT - GAME_LEFT)
    border.right(90)
    border.forward(GAME_TOP - GAME_BOTTOM)
    border.right(90)
border.penup()

crt_pen = turtle.Turtle()
crt_pen.hideturtle()
crt_pen.penup()

score_pen = turtle.Turtle()
score_pen.hideturtle()
score_pen.penup()
score_pen.color(SCORE_COLOR)

lives_pen = turtle.Turtle()
lives_pen.hideturtle()
lives_pen.penup()
lives_pen.color(SCORE_COLOR)

ascii_pen = turtle.Turtle()
ascii_pen.hideturtle()
ascii_pen.penup()
ascii_pen.color("#39FF14")

gameover_pen = turtle.Turtle()
gameover_pen.hideturtle()
gameover_pen.penup()
gameover_pen.color(SCORE_COLOR)

timer_pen = turtle.Turtle()
timer_pen.hideturtle()
timer_pen.penup()
timer_pen.color(SCORE_COLOR)

# --- NUEVO: Lápiz para el mensaje de inicio ---
start_pen = turtle.Turtle()
start_pen.hideturtle()
start_pen.penup()
start_pen.color("#39FF14")

def show_press_key_message():
    start_pen.clear()
    start_pen.goto(0, 20)
    start_pen.write("Pulsa una flecha", align="center", font=("Courier", 22, "bold"))
    start_pen.goto(0, -20)
    start_pen.write("para empezar", align="center", font=("Courier", 22, "bold"))

def hide_press_key_message():
    start_pen.clear()

head = turtle.Turtle()
head.shape("square")
head.color(HEAD_COLOR)
head.penup()
head.goto(0, 0)
head.direction = "stop"
head.hideturtle()

food = turtle.Turtle()
food.shape("square")
food.color(FOOD_COLOR)
food.penup()
food.goto(60, 60)
food.hideturtle()

def draw_ascii_title():
    ascii_pen.clear()
    ascii_art = [
        "  ____  _   _    _    _  __ _____ ",
        " / ___|| \\ | |  / \\  | |/ /| ____|",
        " \\___ \\|  \\| | / _ \\ | ' / |  _|  ",
        "  ___) | |\\  |/ ___ \\| . \\ | |___ ",
        " |____/|_| \\_/_/   \\_\\_|\\_\\|_____|"
    ]
    y = 230
    for line in ascii_art:
        ascii_pen.goto(0, y)
        ascii_pen.write(line, align="center", font=("Courier", 16, "bold"))
        y -= 24

def draw_lives_and_score():
    y = 110
    lives_pen.clear()
    lives_pen.goto(GAME_LEFT + 5, y)
    lives_pen.write(f"VIDAS: {lives}", align="left", font=("Courier", 16, "bold"))
    score_pen.clear()
    score_pen.goto(GAME_RIGHT - 5, y)
    score_pen.write(f"SCORE: {score}", align="right", font=("Courier", 16, "bold"))

def update_info():
    draw_lives_and_score()

def set_game_controls():
    wn.onkey(lambda: start_movement("up"), "Up")
    wn.onkey(lambda: start_movement("down"), "Down")
    wn.onkey(lambda: start_movement("left"), "Left")
    wn.onkey(lambda: start_movement("right"), "Right")

def start_movement(direction):
    global game_state
    if head.direction == "stop" and game_state == "game":
        head.direction = direction
        hide_press_key_message()
        game_loop()
    else:
        if direction == "up" and head.direction != "down":
            head.direction = "up"
        elif direction == "down" and head.direction != "up":
            head.direction = "down"
        elif direction == "left" and head.direction != "right":
            head.direction = "left"
        elif direction == "right" and head.direction != "left":
            head.direction = "right"

def move():
    if head.direction == "up":
        head.sety(head.ycor() + 20)
    elif head.direction == "down":
        head.sety(head.ycor() - 20)
    elif head.direction == "left":
        head.setx(head.xcor() - 20)
    elif head.direction == "right":
        head.setx(head.xcor() + 20)

def random_food_pos(segments):
    positions = set((seg.xcor(), seg.ycor()) for seg in segments)
    positions.add((head.xcor(), head.ycor()))
    tries = 0
    while True:
        x = random.randint(GAME_LEFT//20+1, GAME_RIGHT//20-1) * 20
        y = random.randint(GAME_BOTTOM//20+1, GAME_TOP//20-1) * 20
        if (x, y) not in positions:
            return (x, y)
        tries += 1
        if tries > 100:
            return (0, 0)

def spawn_yellow_food():
    global yellow_food_active, yellow_food_timer
    if game_state != "game" or yellow_food_active:
        return
    x, y = random_food_pos(segments)
    while (x, y) == (food.xcor(), food.ycor()):
        x, y = random_food_pos(segments)
    yellow_food.goto(x, y)
    yellow_food.showturtle()
    yellow_food_active = True
    if yellow_food_timer:
        wn.ontimer(lambda: None, 1)
    yellow_food_timer = wn.ontimer(remove_yellow_food, YELLOW_LIFETIME)

def remove_yellow_food():
    global yellow_food_active, yellow_food_timer
    yellow_food.hideturtle()
    yellow_food_active = False
    yellow_food_timer = None

def menu_clear():
    crt_pen.clear()
    score_pen.clear()
    lives_pen.clear()
    gameover_pen.clear()
    timer_pen.clear()
    # ascii_pen.clear()  # No borrar ASCII

def start_game():
    global score, segments, lives, yellow_food_active, yellow_food_timer, game_state, delay
    menu_clear()
    score = 0
    lives = 3
    delay = START_DELAY
    segments.clear()
    head.goto(0, 0)
    head.direction = "stop"  # Espera al usuario
    x, y = random_food_pos(segments)
    food.goto(x, y)
    head.showturtle()
    food.showturtle()
    yellow_food.hideturtle()
    yellow_food_active = False
    yellow_food_timer = None
    draw_ascii_title()
    show_press_key_message()
    update_info()
    game_state = "game"
    set_game_controls()
    # ¡NO LLAMES A game_loop() AQUÍ!

def handle_death():
    global lives, score, game_state
    if game_state != "game":
        return
    if lives > 1:
        lives -= 1
        score = max(score - 40, 0)
        menu_clear()
        head.goto(0, 0)
        head.direction = "stop"
        for segment in segments:
            segment.goto(1000, 1000)
        segments.clear()
        draw_ascii_title()
        update_info()
        show_press_key_message()
        set_game_controls()
    else:
        lives = 0
        update_info()
        game_state = "over"
        show_gameover_with_timer(5)

def reset_game():
    global score, lives, yellow_food_active, yellow_food_timer, game_state
    head.goto(0, 0)
    head.direction = "stop"
    for segment in segments:
        segment.goto(1000, 1000)
    segments.clear()
    head.hideturtle()
    food.hideturtle()
    yellow_food.hideturtle()
    yellow_food_active = False
    yellow_food_timer = None
    menu_clear()
    draw_ascii_title()
    show_gameover()
    wn.ontimer(start_game, 2000)

def show_gameover():
    menu_clear()
    draw_ascii_title()
    gameover_pen.goto(0, 30)
    gameover_pen.color(SCORE_COLOR)
    gameover_pen.write("GAME OVER", align="center", font=("Courier", 40, "bold"))
    gameover_pen.goto(0, -10)
    gameover_pen.write(f"Puntuación: {score}", align="center", font=("Courier", 24, "bold"))
    update_info()

def show_gameover_with_timer(seconds_left):
    menu_clear()
    draw_ascii_title()
    gameover_pen.goto(0, 30)
    gameover_pen.color(SCORE_COLOR)
    gameover_pen.write("GAME OVER", align="center", font=("Courier", 40, "bold"))
    gameover_pen.goto(0, -10)
    gameover_pen.write(f"Puntuación: {score}", align="center", font=("Courier", 24, "bold"))
    update_info()
    timer_pen.clear()
    timer_pen.goto(0, -50)
    if seconds_left > 0:
        timer_pen.write("Reiniciando en:", align="center", font=("Courier", 22, "bold"))
        timer_pen.goto(0, -80)
        timer_pen.write(f"{seconds_left}...", align="center", font=("Courier", 22, "bold"))
        wn.ontimer(lambda: show_gameover_with_timer(seconds_left - 1), 1000)
    else:
        timer_pen.clear()
        start_game()

def game_loop():
    global score, game_state, lives, yellow_food_active, delay

    if game_state != "game":
        return

    wn.update()

    # COLISIONES (colisión estricta con muro)
    collision = False
    if not (GAME_LEFT+20 <= head.xcor() <= GAME_RIGHT-20 and GAME_BOTTOM+20 <= head.ycor() <= GAME_TOP-20):
        collision = True
    for segment in segments:
        if segment.distance(head) < 20:
            collision = True
            break

    if collision:
        handle_death()
        return

    # Comer fruta normal
    if head.distance(food) < 20:
        x, y = random_food_pos(segments)
        food.goto(x, y)
        new_segment = turtle.Turtle()
        new_segment.shape("square")
        new_segment.color(BODY_COLOR)
        new_segment.penup()
        if segments:
            last = segments[-1]
            new_segment.goto(last.xcor(), last.ycor())
        else:
            new_segment.goto(head.xcor(), head.ycor())
        segments.append(new_segment)
        score += 10
        draw_lives_and_score()
        delay = max(MIN_DELAY, delay - 4)

    # Comer fruta amarilla (vidas)
    if yellow_food_active and head.distance(yellow_food) < 20:
        yellow_food.hideturtle()
        yellow_food_active = False
        if yellow_food_timer:
            wn.ontimer(lambda: None, 1)
        if lives < MAX_LIVES:
            lives += 1
            draw_lives_and_score()

    # Mueve el cuerpo
    for index in range(len(segments) - 1, 0, -1):
        x = segments[index - 1].xcor()
        y = segments[index - 1].ycor()
        segments[index].goto(x, y)
    if len(segments) > 0:
        segments[0].goto(head.xcor(), head.ycor())

    move()
    update_info()

    # Fruta amarilla rara vez
    if (not yellow_food_active) and random.random() < 0.004:
        spawn_yellow_food()

    wn.ontimer(game_loop, delay)

# --- Lanzamiento ---
draw_ascii_title()
set_game_controls()
start_game()
wn.listen()
wn.mainloop()
