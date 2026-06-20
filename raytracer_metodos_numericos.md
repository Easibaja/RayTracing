# Métodos Numéricos detrás de un Ray Tracer en GDScript

**Análisis técnico del módulo `RayTracer.gd`**

---

## 1. Introducción

Un *ray tracer* es, en el fondo, un programa que resuelve el mismo problema matemático millones de veces: dado un punto y una dirección en el espacio 3D, **¿con qué objeto de la escena choca primero?** Ese problema se reduce, una y otra vez, a álgebra lineal de toda la vida: vectores, sistemas de ecuaciones, ecuaciones cuadráticas.

Este documento recorre `RayTracer.gd` identificando, para cada parte del algoritmo, **qué problema numérico está resolviendo y cómo**. La idea es que cada concepto de "gráficos por computadora" (rayo, normal, coordenadas baricéntricas, etc.) se explique primero en términos que ya conocen de cursos de matemática y programación, y luego se nombre con su término técnico.

La estructura general del render es:

```
para cada píxel (x, y) de la imagen:
    construir un rayo que sale de la cámara y pasa por ese píxel
    encontrar el triángulo más cercano que ese rayo toca
    calcular el color en ese punto de impacto (iluminación + sombras)
```

Cada una de esas tres líneas esconde un método numérico distinto.

---

## 2. Representación de un rayo

Un rayo es, matemáticamente, una función paramétrica de una sola variable $t$:

$$
R(t) = \mathbf{O} + t\,\mathbf{D}, \qquad t \geq 0
$$

donde $\mathbf{O} \in \mathbb{R}^3$ es el punto de origen (la cámara) y $\mathbf{D} \in \mathbb{R}^3$ es un vector de dirección **unitario** (norma 1). Esto es exactamente la ecuación vectorial de una recta que ya conocen de álgebra lineal, restringida a $t \geq 0$ (solo la "mitad hacia adelante" de la recta).

En código, esto no es más que dos `Vector3` (dos arreglos de 3 floats):

```gdscript
var origin: Vector3   # O
var direction: Vector3  # D, normalizado
```

Evaluar el rayo en un valor de $t$ dado es una simple combinación lineal: `origin + t * direction`.

---

## 3. De píxel a rayo: un cambio de coordenadas

Para generar la imagen, hay que convertir cada par de enteros $(p_x, p_y)$ (la posición del píxel en la imagen) en un vector de dirección $\mathbf{D}$. Esto es, en esencia, **una composición de transformaciones lineales**, el mismo tipo de operación que se ve en un curso de gráficos o álgebra lineal cuando se multiplica un vector por matrices de cambio de base.

### 3.1 Paso 1: normalizar el píxel a un rango $[-1, 1]$

Dado un ancho $W$ y alto $H$ de imagen, se reescala el índice del píxel a coordenadas continuas (a esto se le llama *NDC*, *normalized device coordinates*, pero es simplemente un reescalado lineal de un intervalo a otro, como cuando se normaliza un dato a $[0,1]$ antes de meterlo a un modelo):

$$
x_{\text{ndc}} = \frac{2\left(p_x + \tfrac12\right)}{W} - 1, \qquad
y_{\text{ndc}} = 1 - \frac{2\left(p_y + \tfrac12\right)}{H}
$$

El `+0.5` apunta al centro del píxel (en vez de su esquina). El signo invertido en $y$ existe porque en la imagen la fila 0 es arriba, pero en el sistema de coordenadas que se usa después, "arriba" es positivo — es un detalle de convención, no de matemática.

### 3.2 Paso 2: aplicar el campo de visión (FOV)

La cámara tiene un ángulo de visión vertical $\theta_{\text{fov}}$. Usando trigonometría básica (un triángulo rectángulo formado por la dirección de la cámara y el borde del campo de visión a distancia 1):

$$
h = \tan\!\left(\frac{\theta_{\text{fov}}}{2}\right)
$$

y la dirección en el sistema de referencia local de la cámara (donde "adelante" es el eje $-z$, por convención de Godot) es:

$$
\mathbf{D}_{\text{cam}} = \big(x_{\text{ndc}} \cdot h \cdot a,\ \ y_{\text{ndc}} \cdot h,\ \ -1\big), \qquad a = \frac{W}{H} \ (\text{aspect ratio})
$$

### 3.3 Paso 3: pasar de coordenadas locales a coordenadas globales

La cámara tiene su propia matriz de orientación $\mathbf{B}$ (una matriz $3\times 3$ ortonormal — sus columnas son los ejes "derecha", "arriba" y "adelante" de la cámara en el mundo). Multiplicar un vector por esa matriz es exactamente el cambio de base que se ve en álgebra lineal:

$$
\mathbf{D} = \frac{\mathbf{B}\,\mathbf{D}_{\text{cam}}}{\lVert \mathbf{B}\,\mathbf{D}_{\text{cam}} \rVert}
$$

Se normaliza al final porque, aunque $\mathbf{B}$ es ortonormal (preserva longitudes), conviene garantizar numéricamente que el resultado sea unitario.

**Resumen de la sección:** generar el rayo de cada píxel es una cadena de tres transformaciones lineales: reescalado, proyección por FOV, y cambio de base. Nada de esto es exclusivo de gráficos — es el mismo tipo de operación matricial que aparece en cualquier pipeline de procesamiento de datos.

---

## 4. El problema central: intersección rayo–triángulo (Möller–Trumbore)

Este es el núcleo numérico de todo el programa, y se ejecuta potencialmente millones de veces por imagen, así que vale la pena entenderlo a fondo.

### 4.1 Planteando el problema como sistema de ecuaciones

Un triángulo en 3D queda definido por tres vértices $V_0, V_1, V_2$. Cualquier punto **dentro del plano del triángulo** se puede escribir como una combinación lineal de los tres vértices, con pesos que suman 1:

$$
P(u, v) = (1 - u - v)\,V_0 + u\,V_1 + v\,V_2
$$

A $(w, u, v) = (1-u-v,\ u,\ v)$ se le llama **coordenadas baricéntricas**. No es más que un sistema de pesos: si $(u, v) = (0, 0)$ estás parado en $V_0$; si $(u,v) = (1,0)$ estás en $V_1$; cualquier combinación intermedia con $u, v \geq 0$ y $u + v \leq 1$ cae **dentro** del triángulo, y fuera de ese rango cae fuera de él. Es análogo a hacer un promedio ponderado.

El punto de intersección del rayo con el plano del triángulo debe satisfacer simultáneamente la ecuación del rayo y la del plano:

$$
\mathbf{O} + t\,\mathbf{D} = (1 - u - v)\,V_0 + u\,V_1 + v\,V_2
$$

Esto son **3 ecuaciones escalares** (una por cada componente $x, y, z$) con **3 incógnitas**: $t$, $u$, $v$. Es decir, un sistema de ecuaciones lineales $3 \times 3$, exactamente como los que se resuelven con eliminación gaussiana en un curso de métodos numéricos.

Reordenando términos (con $\mathbf{e}_1 = V_1 - V_0$, $\mathbf{e}_2 = V_2 - V_0$, $\mathbf{T} = \mathbf{O} - V_0$), el sistema en forma matricial $A\mathbf{x} = \mathbf{b}$ es:

$$
\underbrace{\begin{bmatrix} -\mathbf{D} & \mathbf{e}_1 & \mathbf{e}_2 \end{bmatrix}}_{A}
\begin{bmatrix} t \\ u \\ v \end{bmatrix}
= \mathbf{T}
$$

donde cada columna de $A$ es un vector de $\mathbb{R}^3$.

### 4.2 Resolviendo con la regla de Cramer

Cualquier curso de álgebra lineal enseña que un sistema $A\mathbf{x} = \mathbf{b}$ se puede resolver con eliminación gaussiana, o bien — si $A$ es pequeña — con la **regla de Cramer**:

$$
x_i = \frac{\det(A_i)}{\det(A)}
$$

donde $A_i$ es $A$ con la columna $i$ reemplazada por $\mathbf{b}$. Para una matriz $3\times 3$, cada determinante de $3\times 3$ se puede calcular como un **producto mixto** (también llamado producto triple escalar): $\det[\mathbf{a}\ \mathbf{b}\ \mathbf{c}] = \mathbf{a}\cdot(\mathbf{b}\times\mathbf{c})$.

Esto es clave: en vez de programar una función genérica de inversión de matrices $3\times3$ (con su propio costo en operaciones), Möller–Trumbore aprovecha esa identidad y calcula todo con productos cruz y productos punto, que en GDScript ya vienen como métodos de `Vector3`:

```gdscript
var pvec: Vector3 = ray_dir.cross(edge2)
var det: float = edge1.dot(pvec)
```

Definiendo $\mathbf{P} = \mathbf{D}\times\mathbf{e}_2$ y $\mathbf{Q} = \mathbf{T}\times\mathbf{e}_1$, la solución completa del sistema es:

$$
\det(A) = \mathbf{e}_1\cdot\mathbf{P}, \qquad
u = \frac{\mathbf{T}\cdot\mathbf{P}}{\det(A)}, \qquad
v = \frac{\mathbf{D}\cdot\mathbf{Q}}{\det(A)}, \qquad
t = \frac{\mathbf{e}_2\cdot\mathbf{Q}}{\det(A)}
$$

Esto es **matemáticamente equivalente** a invertir la matriz $A$ y multiplicarla por $\mathbf{b}$, pero con muchas menos operaciones de punto flotante — el mismo tipo de optimización algebraica que se busca al evitar invertir matrices explícitamente cuando hay una forma cerrada más barata.

### 4.3 Casos especiales: cuándo el sistema no tiene solución útil

Tres validaciones, cada una correspondiente a un caso típico de un sistema lineal o de una solución fuera de dominio:

1. **Sistema singular ($\det(A) \approx 0$).** Si el determinante es casi cero, el sistema no tiene solución única — geométricamente, el rayo es paralelo al plano del triángulo (nunca lo toca, o está contenido en él). En vez de dividir por un número cercano a cero (lo cual dispara errores de redondeo enormes en punto flotante), el código simplemente descarta el caso:

   ```gdscript
   if abs(det) < EPSILON:
       return {"hit": false}
   ```

2. **Fuera del dominio válido de $(u, v)$.** Aunque el sistema tenga solución, esa solución puede caer en el plano pero *fuera* del triángulo. Se valida $u \geq 0$, $v \geq 0$, $u + v \leq 1$.

3. **$t$ fuera de rango.** Se exige $t \in (\varepsilon, t_{\max}]$: un $t$ negativo significaría que el triángulo está *detrás* de la cámara, y un $t$ demasiado grande significa que está más lejos de lo que interesa renderizar.

### 4.4 Encontrar el triángulo más cercano

Como la escena tiene muchos triángulos, hay que probar la intersección contra todos y quedarse con el de menor $t$ (el primero que el rayo toca):

```gdscript
for tri in triangulos:
    var res = intersect_triangle(origin, dir, tri, closest_t)
    if res.hit and res.t < closest_t:
        closest_t = res.t
        # actualizar el resultado
```

Esto es, en esencia, un algoritmo de búsqueda de mínimo sobre una lista, ejecutado por cada rayo — de ahí que el costo por rayo sea, en el caso ingenuo, $O(N)$ con $N$ el número de triángulos.

---

## 5. Acelerar la búsqueda: poda con una esfera envolvente

Probar cada rayo contra **cada triángulo** de la escena es caro: si hay $M$ rayos y $N$ triángulos, el costo total es $O(M \cdot N)$. La optimización implementada es un caso simple de lo que en algoritmos se llama *poda* (*pruning*): antes de probar los triángulos de un objeto uno por uno, se hace primero una prueba mucho más barata que descarta el objeto completo si es imposible que el rayo lo toque.

### 5.1 El test barato: intersección rayo–esfera

Se envuelve cada grupo de triángulos (por ejemplo, todos los que forman una fruta del modelo 3D) en una esfera que los contiene a todos. Probar si un rayo toca una esfera es mucho más barato que probarlo contra decenas de triángulos, porque se reduce a **resolver una ecuación cuadrática**.

La condición de que el rayo toque la esfera de centro $C$ y radio $r$ es:

$$
\lVert \mathbf{O} + t\mathbf{D} - C \rVert^2 = r^2
$$

Expandiendo el cuadrado (y usando que $\lVert\mathbf{D}\rVert = 1$), queda una ecuación cuadrática estándar en $t$:

$$
t^2 + 2bt + c = 0, \qquad b = (\mathbf{O}-C)\cdot\mathbf{D}, \qquad c = \lVert\mathbf{O}-C\rVert^2 - r^2
$$

De la fórmula general $t = \dfrac{-b \pm \sqrt{b^2 - c}}{1}$, lo único que interesa para esta prueba de "¿podría tocarla?" es si el **discriminante**

$$
\Delta = b^2 - c
$$

es no negativo. No hace falta calcular las raíces — solo evaluar el signo del discriminante, igual que cuando en precálculo se pregunta "¿cuántas soluciones reales tiene esta cuadrática?" sin necesariamente resolverla:

```gdscript
var discriminant: float = b * b - c
return discriminant >= 0.0 and b <= sqrt(discriminant)
```

Si $\Delta < 0$, se descartan **todos** los triángulos de ese grupo sin probarlos individualmente.

### 5.2 Impacto en complejidad

Con $G$ grupos de malla, el costo por rayo pasa de $O(N)$ (probar todos los triángulos) a aproximadamente $O(G + N_{\text{golpeados}})$, donde $N_{\text{golpeados}}$ es solo la cantidad de triángulos que pertenecen a grupos cuya esfera sí fue tocada. Es la misma idea que usar un índice o una estructura auxiliar para evitar un recorrido lineal completo de los datos.

La esfera en sí se calcula con estadística descriptiva básica: el centro es el promedio de todos los vértices, y el radio es la distancia máxima de cualquier vértice a ese centro:

$$
C = \frac{1}{3n}\sum_{i=1}^n (V_0^{(i)} + V_1^{(i)} + V_2^{(i)}), \qquad r = \max_i \lVert V_j^{(i)} - C\rVert
$$

No es la esfera mínima óptima (encontrar esa es un problema de optimización más caro), pero es una aproximación suficientemente buena y barata de calcular.

---

## 6. Vectores unitarios y división por cero

Varias partes del código necesitan vectores de longitud 1 (direcciones "puras", sin magnitud), obtenidos con la operación estándar:

$$
\hat{\mathbf{v}} = \frac{\mathbf{v}}{\lVert\mathbf{v}\rVert}, \qquad \lVert\mathbf{v}\rVert = \sqrt{v_x^2+v_y^2+v_z^2}
$$

El problema clásico de estabilidad numérica aparece cuando $\lVert\mathbf{v}\rVert \to 0$: dividir por un número cercano a cero amplifica brutalmente cualquier error de redondeo, y en el límite produce `NaN` o `inf`. El código agrega chequeos explícitos antes de normalizar vectores que podrían tener longitud casi nula (por ejemplo, el vector hacia una luz puntual cuando el punto evaluado está casi exactamente en la posición de la luz), tratando ese caso por separado en vez de dejar que la división explote.

---

## 7. Interpolación: de vértices a cualquier punto del triángulo

Las coordenadas baricéntricas $(w, u, v)$ que salieron como subproducto de resolver el sistema en la Sección 4 no solo sirven para decidir si el punto está dentro del triángulo — también sirven para **interpolar cualquier dato asociado a los vértices** hacia el punto exacto de impacto.

Por ejemplo, si cada vértice tiene su propio vector normal $\mathbf{n}_0, \mathbf{n}_1, \mathbf{n}_2$ (la dirección "hacia afuera" de la superficie en ese vértice), la normal en el punto de impacto se aproxima como el mismo promedio ponderado:

$$
\hat{\mathbf{N}} = \frac{w\,\mathbf{n}_0 + u\,\mathbf{n}_1 + v\,\mathbf{n}_2}{\lVert w\,\mathbf{n}_0 + u\,\mathbf{n}_1 + v\,\mathbf{n}_2 \rVert}
$$

Esto es exactamente el mismo tipo de interpolación lineal que se usaría para, por ejemplo, estimar un valor entre tres puntos de datos conocidos dada su posición relativa — solo que aquí los "datos" son vectores de dirección en vez de escalares. Lo mismo se aplica para interpolar coordenadas de textura (UV) cuando el modelo tiene una imagen aplicada como color.

---

## 8. Modelo de iluminación: ley del coseno (Lambert)

Una vez que se sabe en qué punto y con qué normal el rayo chocó, falta calcular el color visible ahí. El modelo usado es el más simple y común en gráficos: **iluminación difusa Lambertiana**, que dice que la cantidad de luz reflejada depende del coseno del ángulo entre la normal de la superficie y la dirección hacia la luz:

$$
I_{\text{diff}} = \max(0,\ \hat{\mathbf{N}} \cdot \hat{\mathbf{L}})
$$

Como $\hat{\mathbf{N}}$ y $\hat{\mathbf{L}}$ son vectores unitarios, su producto punto **es** el coseno del ángulo entre ellos (identidad básica de álgebra lineal: $\mathbf{a}\cdot\mathbf{b} = \lVert\mathbf{a}\rVert\lVert\mathbf{b}\rVert\cos\theta$). Si la superficie mira directo a la luz, el coseno es 1 (máxima iluminación); si está de perfil, es 0; si mira en sentido contrario, sería negativo, por lo que se recorta con $\max(0, \cdot)$ — una superficie no puede "restar" luz.

### 8.1 Atenuación por distancia (ley del inverso del cuadrado)

Para una luz puntual, la intensidad decae con la distancia $d$ porque la misma energía se reparte sobre una esfera cada vez más grande (área $4\pi d^2$):

$$
A(d) = \frac{1}{1+d^2}
$$

Esta es una versión "suavizada" de la fórmula física exacta $1/d^2$: se le suma 1 al denominador específicamente para evitar la división por cero (o un valor absurdamente grande) cuando $d \to 0$ — el mismo truco de regularización que se usa en otros contextos numéricos para evitar singularidades, a costa de un pequeño error en la física exacta.

### 8.2 Rayos de sombra y el sesgo numérico (*shadow bias*)

Para saber si un punto está en sombra, se lanza un **segundo rayo** desde el punto de impacto hacia la luz, y se reutiliza exactamente la misma función de intersección de la Sección 4. Si ese rayo choca con algo antes de llegar a la luz, el punto está en sombra.

Aquí aparece un problema sutil de punto flotante: el punto de partida de ese segundo rayo **ya es el resultado de un cálculo numérico previo** (la intersección original), así que tiene un pequeño error de redondeo. Si se usa exactamente ese punto como origen, el nuevo rayo puede "autointersecar" la misma superficie de la que partió, en $t \approx 0$, por culpa de ese error — produciendo sombras incorrectas (un patrón con textura de moaré conocido como *shadow acne*).

La solución es desplazar el origen un poquito a lo largo de la normal antes de lanzar el rayo de sombra:

$$
\mathbf{O}_{\text{sombra}} = P + \delta\,\hat{\mathbf{N}}, \qquad \delta = 10^{-4}
$$

Es, en esencia, una tolerancia numérica (parecida a un `epsilon` de comparación de floats), aplicada geométricamente en vez de aritméticamente.

### 8.3 Combinando todo en el color final

$$
I = k_a + I_{\text{diff}}\cdot S \cdot (1-k_a), \qquad
C_{\text{final}} = \text{clamp}\big(C_{\text{superficie}}\cdot I \cdot C_{\text{luz}},\ 0,\ 1\big)
$$

donde $k_a$ es un término ambiental constante (para que las sombras no sean negro absoluto) y $S \in \{0,1\}$ es el factor de sombra. El `clamp` final a $[0,1]$ es necesario porque, al multiplicar varios términos, el resultado podría salirse del rango representable de color.

---

## 9. Antialiasing como integración numérica (Monte Carlo)

Cuando `samples_per_pixel > 1`, en vez de evaluar el color en el centro exacto de cada píxel, se toman $N$ muestras en posiciones aleatorias dentro del área del píxel y se promedian:

$$
C(p_x, p_y) \approx \frac{1}{N}\sum_{k=1}^{N} L\big(R(p_x + \xi_k^{(1)},\ p_y + \xi_k^{(2)})\big), \qquad \xi_k^{(1)}, \xi_k^{(2)} \sim \mathcal{U}(0,1)
$$

Conceptualmente, el color "verdadero" de un píxel es el promedio (la integral) del color sobre toda su área, no un único valor puntual. Como esa integral no tiene una fórmula cerrada simple para una escena arbitraria, se **estima por muestreo aleatorio** — exactamente el mismo principio que un método de Monte Carlo para aproximar una integral o una probabilidad: en vez de calcular el valor exacto, se promedian muchas evaluaciones aleatorias y el resultado converge al valor real a medida que $N$ crece (con error decreciendo proporcional a $O(1/\sqrt{N})$, la tasa de convergencia típica de Monte Carlo).

```gdscript
for s in range(samples_per_pixel):
    var jx = px + rng.randf()   # punto aleatorio dentro del píxel
    var jy = py + rng.randf()
    accum += shade(intersect_scene(...))
accum /= float(samples_per_pixel)
```

El efecto práctico es que los bordes de los objetos (donde un píxel "tapa" parcialmente dos superficies distintas) se ven suavizados en vez de tener el efecto de escalera (*aliasing*) típico de muestrear un solo punto por píxel.

---

## 10. Resumen de métodos numéricos identificados

| Método numérico | Dónde aparece | Problema que resuelve |
|---|---|---|
| Transformaciones lineales / cambio de base | Generación de rayos de cámara | Píxel discreto → dirección 3D |
| Sistema de ecuaciones lineales $3\times3$ (regla de Cramer) | Möller–Trumbore | Intersección rayo–triángulo |
| Producto cruz y producto punto como atajo algebraico | Möller–Trumbore | Evitar inversión explícita de matriz |
| Ecuación cuadrática (discriminante) | Intersección rayo–esfera | Poda rápida antes de probar triángulos |
| Normalización vectorial con guarda contra división por cero | Varias partes | Estabilidad numérica |
| Interpolación lineal ponderada (coordenadas baricéntricas) | Normales y UVs por píxel | Pasar de datos por vértice a datos por punto |
| Producto punto como coseno de ángulo | Iluminación Lambertiana | Modelo de reflectancia difusa |
| Regularización de singularidad ($+1$ en denominador) | Atenuación de luz | Evitar división por distancia cero |
| Sesgo numérico (epsilon geométrico) | Rayos de sombra | Evitar error de redondeo acumulado |
| Muestreo aleatorio / Monte Carlo | Supersampling | Antialiasing por integración estimada |

---

## 11. Conclusión

Lo interesante de este ray tracer, visto desde Ciencias de la Computación, es que **no usa ningún algoritmo "de gráficos" que no sea, en el fondo, álgebra lineal y cálculo numérico estándar** aplicado de forma repetida: resolver sistemas lineales pequeños millones de veces, evaluar discriminantes de cuadráticas para podar trabajo innecesario, manejar con cuidado los casos límite de punto flotante (división por cero, error de redondeo acumulado), y estimar integrales por muestreo aleatorio cuando no hay fórmula cerrada. El algoritmo de Möller–Trumbore en particular es un buen ejemplo de cómo una reformulación algebraica equivalente (usar productos cruz/punto en vez de invertir una matriz $3\times3$ de forma genérica) puede reducir el costo computacional sin perder exactitud — un criterio de eficiencia que aplica igual de bien fuera del contexto de gráficos.
