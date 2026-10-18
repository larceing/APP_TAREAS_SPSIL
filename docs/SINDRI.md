# Sindri: clientes y facturación central

Módulo opcional (`MODULO_SINDRI=1`). Sindri es donde la empresa tiene sus clientes y factura. Con
su llave de integración, el gestor de tareas:

- **liga cada empresa** con su cliente de Sindri, o da de alta como empresa un cliente de allí;
- le **manda a facturar el tiempo real** de las tareas hechas (en una columna de hechas, con
  tiempo real y de una empresa ligada). Aparecen en Sindri → Pedidos → Por facturar, una línea
  por tarea, con el producto `SINDRI_PRODUCTO` (HORA si no se dice) a la tarifa que tenga en
  Sindri. Desde ahí se pasan a un pedido y se facturan.

Todo está en **Configuración → Sindri** (solo IT).

## Conectar

1. En Sindri, con la empresa elegida: **Empresa → Integraciones → Nueva llave**, nombre `tareas`.
   La llave (`sdi_…`) se ve una sola vez.
2. En `app_fastapi/.env`: `MODULO_SINDRI=1`, `SINDRI_URL=<dirección de Sindri>`,
   `SINDRI_LLAVE=sdi_…` y, si las horas no van con el producto HORA, `SINDRI_PRODUCTO=<sku>`.
3. En una instalación que ya existía: `python scripts/migrar_sindri.py` (añade las columnas).

## Cómo se comporta

- La referencia de cada tarea en Sindri es `tarea-<id>`: mandar otra vez no duplica.
- Una tarea mandada ya no sale en "Por mandar". En "Mandadas a Sindri" se ve si sigue por
  facturar, en qué pedido está o si allí se descartó ("Traer estado de Sindri" lo refresca).
- Mientras siga por facturar en Sindri, "Retirar" la quita de allí y vuelve a "Por mandar".
- El día de la tarea es el de su cierre (`cerrada_en`), o el de su última modificación si no lo tiene.

La API de Sindri está descrita en `docs/INTEGRACIONES.md` del repositorio de Sindri.
