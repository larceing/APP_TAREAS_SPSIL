# -*- coding: utf-8 -*-
"""Modulo opcional sindri (MODULO_SINDRI): Sindri es la facturacion central.

Con su llave de integracion (Sindri -> Empresa -> Integraciones) la app:
  - liga cada empresa con su cliente de Sindri, o la trae de alli;
  - le manda a facturar el tiempo real de las tareas hechas (columna es_done)
    de empresas ligadas. Aparecen en Sindri -> Pedidos -> Por facturar con el
    producto SINDRI_PRODUCTO (HORA si no se dice) a su tarifa.
La referencia de cada tarea es "tarea-<id>": mandarla otra vez actualiza lo que
haya en Sindri, nunca duplica. Contrato de la API: docs/SINDRI.md."""
import os
import uuid

import requests

from . import db


class SindriError(Exception):
    pass


def _url() -> str:
    return (os.getenv("SINDRI_URL") or "").strip().rstrip("/")


def _llave() -> str:
    return (os.getenv("SINDRI_LLAVE") or "").strip()


def producto() -> str:
    return (os.getenv("SINDRI_PRODUCTO") or "").strip() or "HORA"


def configurado() -> bool:
    return bool(_url() and _llave())


def _llamar(metodo: str, ruta: str, cuerpo=None, timeout: int = 30):
    if not configurado():
        raise SindriError("Sindri no está configurado (SINDRI_URL y SINDRI_LLAVE en el .env).")
    try:
        r = requests.request(metodo, _url() + "/api/integracion/v1" + ruta, json=cuerpo, timeout=timeout,
                             headers={"Authorization": "Bearer " + _llave()})
    except requests.RequestException:
        raise SindriError("No se puede conectar con Sindri.")
    try:
        datos = r.json()
    except ValueError:
        datos = {}
    if r.status_code == 401:
        raise SindriError("Sindri no acepta la llave: revisa SINDRI_LLAVE.")
    if r.status_code >= 400:
        e = SindriError("Sindri: " + str((datos or {}).get("error") or f"error {r.status_code}"))
        e.status = r.status_code
        raise e
    return datos


def estado() -> dict:
    """Para la pestaña de Configuración: si hay conexión y con qué empresa."""
    if not configurado():
        return {"configurado": False}
    try:
        yo = _llamar("GET", "/yo", timeout=5)
        return {"configurado": True, "empresa": yo.get("empresa") or {}, "producto": producto()}
    except SindriError as e:
        return {"configurado": True, "error": str(e)}


def clientes() -> list:
    return _llamar("GET", "/clientes")


def ligar(empresa_id: str, sindri_id: str) -> None:
    if sindri_id and not any(c["id"] == sindri_id for c in clientes()):
        raise SindriError("Ese cliente no está en Sindri.")
    db.set_empresa_sindri(empresa_id, sindri_id)


def importar(sindri_id: str) -> str:
    """Da de alta como empresa un cliente de Sindri, ya ligado. Si ya hay una
    empresa con el mismo nombre, solo la liga. Devuelve el nombre."""
    c = next((x for x in clientes() if x["id"] == sindri_id), None)
    if not c:
        raise SindriError("Ese cliente no está en Sindri.")
    nombre = (c.get("trade_name") or c.get("name") or "").strip()[:150]
    existente = next((e for e in db.empresas_sindri() if e["nombre"].strip().lower() == nombre.lower()), None)
    if existente:
        db.set_empresa_sindri(existente["empresa_id"], c["id"])
        return existente["nombre"]
    empresa_id = uuid.uuid4().hex
    db.crear_empresa(empresa_id, nombre, (c.get("name") or "")[:200], "#6b7280", "")
    db.set_empresa_sindri(empresa_id, c["id"])
    return nombre


def ref_de(tarea_id: str) -> str:
    return f"tarea-{tarea_id}"


def elemento_de(t: dict) -> dict:
    return {
        "ref": ref_de(t["tarea_id"]), "cliente": t["sindri_id"], "producto": producto(), "fecha": t["dia"],
        "cantidad": f"{t['horas']:g}", "descripcion": f"{t['proyecto']}: {t['titulo']}"[:1000],
    }


def enviar(desde: str, hasta: str) -> dict:
    """Manda a Sindri las tareas hechas del periodo de empresas ligadas."""
    tareas = db.tareas_por_facturar(desde, hasta)
    ligadas = [t for t in tareas if t["sindri_id"]]
    res = {"enviadas": 0, "sin_empresa": len(tareas) - len(ligadas), "errores": []}
    for i in range(0, len(ligadas), 500):
        lote = {ref_de(t["tarea_id"]): t for t in ligadas[i:i + 500]}
        r = _llamar("POST", "/por-facturar", {"elementos": [elemento_de(t) for t in lote.values()]})
        for e in r.get("elementos") or []:
            t = lote.get(e.get("ref"))
            if not t:
                continue
            if e.get("estado") == "error":
                res["errores"].append(f"{t['titulo']}: {e.get('error') or 'error'}")
                continue
            estado_sindri = "pendiente" if e["estado"] in ("creado", "actualizado") else e["estado"]
            db.marcar_tarea_sindri(t["tarea_id"], estado_sindri, e.get("pedido") or "", enviada=True)
            res["enviadas"] += 1
    return res


def actualizar() -> int:
    """Trae de Sindri en qué punto está lo mandado. Devuelve cuántas cambiaron."""
    tareas = db.tareas_en_sindri()
    cambiadas = 0
    for i in range(0, len(tareas), 50):
        lote = {ref_de(t["tarea_id"]): t for t in tareas[i:i + 50]}
        for e in _llamar("GET", "/por-facturar?refs=" + ",".join(lote)):
            t = lote.get(e.get("ref"))
            pedido = e.get("pedido") or ""
            if t and (t["sindri_estado"], t["sindri_pedido"]) != (e["estado"], pedido):
                db.marcar_tarea_sindri(t["tarea_id"], e["estado"], pedido)
                cambiadas += 1
    return cambiadas


def retirar(tarea_id: str) -> None:
    """Quita de Sindri una tarea que alli sigue pendiente (vuelve a 'por facturar')."""
    try:
        _llamar("DELETE", "/por-facturar/" + ref_de(tarea_id))
    except SindriError as e:
        if getattr(e, "status", None) != 404:
            raise
    db.soltar_tarea_sindri(tarea_id)
