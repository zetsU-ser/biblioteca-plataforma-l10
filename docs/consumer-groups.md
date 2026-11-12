# Consumer groups de la biblioteca

Todos viven en `biblioteca-eventos/src/streaming/`, uno por carpeta y por módulo de Nest. Cada grupo tiene dos
clases: la de Kafka (`<grupo>.consumidor.ts`, que hereda de `consumidor-kafka.ts`: conexión, suscripción y
commit) y la de negocio (`<grupo>.negocio.ts`: recibe el evento ya validado por `contrato.ts` y escribe en
Postgres). La clase de negocio no importa nada de Kafka.

| Consumer group | Lee | Escribe | Idempotencia |
|---|---|---|---|
| `biblioteca-panel` | `biblioteca.lecturas`, `biblioteca.prestamos` | `kpi_minuto` | Una fila por evento: `evento_id` es la clave primaria |
| `biblioteca-alertas` | `biblioteca.lecturas` | `ventanas_lectura`, `alertas` | `eventos_procesados (grupo, evento_id)` en la misma transacción que suma |
| `biblioteca-historial` | `biblioteca.prestamos` | `prestamos_semana`, `prestamos_vistos` | `eventos_procesados (grupo, evento_id)` en la misma transacción que suma |
| `biblioteca-catalogo` | `biblioteca.catalogo` | `catalogo_libros` | Se escribe el libro completo encima; no retrocede a un `emitidoEn` anterior |

Además, `biblioteca-libros` usa el grupo `biblioteca-libros` solo para leer su propio topic al arrancar, sin
confirmar offsets (ver `catalogo-kafka.mjs` en `biblioteca-libros`).

## El orden: escribir y después confirmar

```ts
for await (const m of flujo) {
  let evento;
  try {
    evento = this.contrato.validar(m);                       // JSON y DTO; si falla, lanza EventoInvalido
  } catch (error) {
    this.log.warn(`${donde} INVALIDO: ${error.message}`);    // en la E3, al .dlt
    await m.commit();                                        // reintentar no lo arregla
    continue;
  }
  const resultado = await this.procesarHastaEscribir(evento, donde); // INSERT; si es duplicado, no suma
  await m.commit();                                          // recién ahora
}
```

Commit manual después de escribir más idempotencia: entrega al menos una vez y resultado exactamente una vez. Si
el proceso muere entre el `INSERT` y el `commit`, al volver relee ese evento y el `INSERT` no suma. Un evento que
no cumple el contrato se registra y se confirma. Si lo que falla es Postgres, **no** se confirma: el mismo evento
se reintenta cada 2 segundos hasta que se pueda escribir (confirmarlo lo perdería).

## Por qué dos formas de idempotencia

- **`kpi_minuto`, una fila por evento.** El panel necesita contar por minuto y por libro, y la serie acumulada de
  lecturas en curso; con una fila por evento eso es un `GROUP BY` al leer, y el duplicado se descarta con
  `ON CONFLICT (evento_id) DO NOTHING`. Son 2.626 filas por noche: nada para Postgres.
- **`ventanas_lectura` y `prestamos_semana`, contadores.** La alerta se evalúa con cada lectura terminada y el
  historial asocia la devolución a su préstamo: los dos necesitan el total al momento, no al leer. El contador se
  suma en la misma transacción que registra `(grupo, evento_id)` en `eventos_procesados`; si el par ya estaba, la
  transacción no suma. La clave lleva el grupo porque el mismo evento lo procesan dos grupos.

## La regla de las alertas, y por qué un mínimo de 5

Por libro, en ventanas fijas de 5 minutos de `emitidoEn` (UTC; el panel las muestra en hora de Chile): alerta si
**más del 20%** de las lecturas terminadas fue `error` **y hubo al menos 5 terminadas**. Con cada terminada se
evalúa la ventana otra vez: si cumple, la alerta queda con las cifras al día; si deja de cumplir, se retira.

Sin mínimo, con el dataset de ejemplo también disparan dos ventanas que no son una racha:

| Libro | Ventana | En error / terminadas | Con mínimo de 5 |
|---|---|---|---|
| `18` | 21:05 a 21:10 | 1 / 3 (33,3%) | no dispara |
| **`10`** | **21:30 a 21:35** | **56 / 59 (94,9%)** | **dispara** |
| `16` | 21:50 a 21:55 | 1 / 3 (33,3%) | no dispara |

Con 4 o menos terminadas, **una sola** en error ya pasa el 20%: la alerta diría «falló una lectura», no «este
libro tiene un problema». La mediana es de 2 terminadas por ventana (187 ventanas con alguna terminada), y la
racha real tiene 59. Con 5, un error no basta (1 de 5 es 20%, no más): hacen falta 2. Un mínimo de 3 dejaría
pasar las dos ventanas de arriba.

## La devolución y su préstamo

`prestamo.devuelto` no dice en qué semana se prestó. `biblioteca-historial` guarda cada préstamo en
`prestamos_vistos` y, al llegar la devolución, lo busca por `prestamoId`, lo marca devuelto y resta un activo en la
semana y el libro **del préstamo**. Funciona sin esperas porque la key es `usuarioSub`: el préstamo y su
devolución caen en la misma partición y la devolución se lee después. Una segunda devolución del mismo préstamo
no resta otra vez. La semana es el lunes, en hora de Chile, de `emitidoEn` (2026-11-02 para toda la noche).

## Dos grupos sobre el mismo topic: cada uno con su offset

`biblioteca-panel` y `biblioteca-historial` leen `biblioteca.prestamos`. Con `eventos` detenido, se rebobinó solo
`biblioteca-historial`; `biblioteca-panel` siguió en el final, con lag 0 (salida del ensayo, después de dos
reproducciones):

```
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --group biblioteca-panel
Consumer group 'biblioteca-panel' has no active members.
GROUP             TOPIC                 PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
biblioteca-panel  biblioteca.prestamos  0          272             272             0
biblioteca-panel  biblioteca.prestamos  1          290             290             0
biblioteca-panel  biblioteca.prestamos  2          246             246             0
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --group biblioteca-historial
Consumer group 'biblioteca-historial' has no active members.
GROUP                 TOPIC                 PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
biblioteca-historial  biblioteca.prestamos  0          0               272             272
biblioteca-historial  biblioteca.prestamos  1          0               290             290
biblioteca-historial  biblioteca.prestamos  2          0               246             246
```

(Las líneas de `biblioteca.lecturas` del panel se omiten.) Al levantar `eventos`, `biblioteca-historial` releyó
los 808 mensajes (398 nuevos tras vaciar su tabla, 402 duplicados y 8 inválidos) y `biblioteca-panel` no leyó
nada: el panel no se enteró. Lo mismo pasa con `biblioteca-panel` y `biblioteca-alertas` sobre
`biblioteca.lecturas`: cada uno avanza con su propio `CURRENT-OFFSET`.

## Las particiones se reparten dentro de un grupo

Con tres instancias de `biblioteca-eventos` (`docker compose run -d --no-deps --name eventos-2 eventos`, y
`eventos-3`), cada instancia toma una partición de cada topic; `biblioteca-panel`, que lee dos topics, toma dos:

```
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --members --group biblioteca-alertas
GROUP               CONSUMER-ID                                              HOST          CLIENT-ID           #PARTITIONS
biblioteca-alertas  biblioteca-eventos-bcf78698-6d6f-4688-a653-ed1d925a5cb6  /172.19.0.14  biblioteca-eventos  1
biblioteca-alertas  biblioteca-eventos-a4726f3a-f26a-46a4-a242-de556dd66e99  /172.19.0.19  biblioteca-eventos  1
biblioteca-alertas  biblioteca-eventos-a8a09266-592b-4502-a4ab-6ab0dea7b7c5  /172.19.0.16  biblioteca-eventos  1
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --members --group biblioteca-panel
GROUP             CONSUMER-ID                                              HOST          CLIENT-ID           #PARTITIONS
biblioteca-panel  biblioteca-eventos-1566bcf0-322e-49a0-a4d0-109c19765aa0  /172.19.0.14  biblioteca-eventos  2
biblioteca-panel  biblioteca-eventos-6f31b2af-d7a1-4a47-8c5f-ee0b480daac7  /172.19.0.19  biblioteca-eventos  2
biblioteca-panel  biblioteca-eventos-1ac3f57f-220d-4f7a-a419-ec9f5815bd99  /172.19.0.16  biblioteca-eventos  2
```

Con cuatro (`eventos-4`), en los grupos que leen un solo topic de 3 particiones **una instancia queda sin
nada**; en `biblioteca-panel`, 6 particiones entre 4, queda 2, 2, 1 y 1:

```
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --members --group biblioteca-alertas
GROUP               CONSUMER-ID                                              HOST          CLIENT-ID           #PARTITIONS
biblioteca-alertas  biblioteca-eventos-bcf78698-6d6f-4688-a653-ed1d925a5cb6  /172.19.0.14  biblioteca-eventos  1
biblioteca-alertas  biblioteca-eventos-a4726f3a-f26a-46a4-a242-de556dd66e99  /172.19.0.19  biblioteca-eventos  1
biblioteca-alertas  biblioteca-eventos-96bd3169-355a-4d7e-b9c4-8426a4648831  /172.19.0.20  biblioteca-eventos  1
biblioteca-alertas  biblioteca-eventos-a8a09266-592b-4502-a4ab-6ab0dea7b7c5  /172.19.0.16  biblioteca-eventos  0
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --members --group biblioteca-historial
GROUP                 CONSUMER-ID                                              HOST          CLIENT-ID           #PARTITIONS
biblioteca-historial  biblioteca-eventos-167b8e4d-8c5d-42f4-83e8-8d39f80c63ad  /172.19.0.16  biblioteca-eventos  1
biblioteca-historial  biblioteca-eventos-f85b4d9e-ad0d-4a27-aabd-938802780873  /172.19.0.14  biblioteca-eventos  1
biblioteca-historial  biblioteca-eventos-d3fb002b-8d28-4051-a16c-2fcb73bc9291  /172.19.0.20  biblioteca-eventos  1
biblioteca-historial  biblioteca-eventos-9f29f89a-398b-4a14-86da-87502688133e  /172.19.0.19  biblioteca-eventos  0
$ kafka-consumer-groups.sh --bootstrap-server broker-1:19092 --describe --members --group biblioteca-panel
GROUP             CONSUMER-ID                                              HOST          CLIENT-ID           #PARTITIONS
biblioteca-panel  biblioteca-eventos-1566bcf0-322e-49a0-a4d0-109c19765aa0  /172.19.0.14  biblioteca-eventos  2
biblioteca-panel  biblioteca-eventos-6f31b2af-d7a1-4a47-8c5f-ee0b480daac7  /172.19.0.19  biblioteca-eventos  2
biblioteca-panel  biblioteca-eventos-78cd7647-6246-4ed7-9432-24304494e2c9  /172.19.0.20  biblioteca-eventos  1
biblioteca-panel  biblioteca-eventos-1ac3f57f-220d-4f7a-a419-ec9f5815bd99  /172.19.0.16  biblioteca-eventos  1
```

Por eso 3 particiones: más instancias que particiones no leen más rápido, solo esperan. Al quitar las tres
instancias extra (`docker stop` y `docker rm`), la que queda vuelve a tomar las 3 particiones de cada topic.

## Rebobinar y repetir

El procedimiento (detener `eventos`, `--reset-offsets --to-earliest`, levantar) y la limpieza para repetir una
demostración están en el `README.md`, sección «Kafka (L10)».