# -*- coding: utf-8 -*-
"""Columnas del modulo sindri en una instalacion que ya existe (en una nueva
las crea instalar.py desde schema_app_tareas.sql). Se puede lanzar las veces
que haga falta: solo anade lo que falte, en la BD real y en la de pruebas.

    python scripts/migrar_sindri.py
"""
import os

from _comun import conectar

SENTENCIAS = [
    "ALTER TABLE empresas ADD COLUMN IF NOT EXISTS sindri_id VARCHAR(64) NOT NULL DEFAULT ''",
    "ALTER TABLE tareas ADD COLUMN IF NOT EXISTS sindri_en DATETIME NULL",
    "ALTER TABLE tareas ADD COLUMN IF NOT EXISTS sindri_estado VARCHAR(16) NOT NULL DEFAULT ''",
    "ALTER TABLE tareas ADD COLUMN IF NOT EXISTS sindri_pedido VARCHAR(40) NOT NULL DEFAULT ''",
]


def migrar(nombre_bd: str) -> None:
    conn = conectar(nombre_bd)
    try:
        with conn.cursor() as cur:
            for sql in SENTENCIAS:
                cur.execute(sql)
        conn.commit()
    finally:
        conn.close()
    print(f"{nombre_bd}: columnas de Sindri al dia")


if __name__ == "__main__":
    for bd in dict.fromkeys(filter(None, (os.getenv("DB_NAME"), os.getenv("DB_NAME_TEST")))):
        migrar(bd)
