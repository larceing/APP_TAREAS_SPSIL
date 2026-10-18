# -*- coding: utf-8 -*-
"""Configuracion -> Sindri (modulo opcional MODULO_SINDRI): ligar empresas con
clientes de Sindri y mandarle a facturar el tiempo de las tareas hechas. El
panel lo pinta _config_sindri.html; aqui solo los POST. Solo IT."""
import re

from fastapi import APIRouter, Depends, Form
from fastapi.requests import Request
from fastapi.responses import RedirectResponse

from .. import auth, sindri
from ..flash import flash

router = APIRouter(prefix="/configuracion/sindri", tags=["sindri"], dependencies=[Depends(auth.requiere_it)])

_DIA = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _volver(desde: str = "", hasta: str = "") -> RedirectResponse:
    extra = f"&desde={desde}&hasta={hasta}" if _DIA.match(desde) and _DIA.match(hasta) else ""
    return RedirectResponse(url="/configuracion/?tipo=sindri" + extra, status_code=303)


@router.post("/ligar/")
def ligar(request: Request, empresa_id: str = Form(...), sindri_id: str = Form("")):
    try:
        sindri.ligar(empresa_id, sindri_id.strip())
        flash(request, "success", "Empresa ligada con Sindri." if sindri_id else "Empresa sin ligar.")
    except sindri.SindriError as e:
        flash(request, "error", str(e))
    return _volver()


@router.post("/importar/")
def importar(request: Request, sindri_id: str = Form(...)):
    try:
        flash(request, "success", f"'{sindri.importar(sindri_id.strip())}' ligada con su cliente de Sindri.")
    except sindri.SindriError as e:
        flash(request, "error", str(e))
    return _volver()


@router.post("/enviar/")
def enviar(request: Request, desde: str = Form(...), hasta: str = Form(...)):
    if not (_DIA.match(desde) and _DIA.match(hasta)) or hasta < desde:
        flash(request, "error", "Indica un periodo válido.")
        return _volver()
    try:
        r = sindri.enviar(desde, hasta)
        partes = [f"{r['enviadas']} tareas mandadas a Sindri."]
        if r["sin_empresa"]:
            partes.append(f"{r['sin_empresa']} sin mandar: su empresa no está ligada (o no tienen empresa).")
        if r["errores"]:
            partes.append("Con error: " + "; ".join(r["errores"][:5]) + ("…" if len(r["errores"]) > 5 else ""))
        flash(request, "error" if r["errores"] else "success", " ".join(partes))
    except sindri.SindriError as e:
        flash(request, "error", str(e))
    return _volver(desde, hasta)


@router.post("/actualizar/")
def actualizar(request: Request):
    try:
        flash(request, "success", f"Estado traído de Sindri: {sindri.actualizar()} tareas cambiaron.")
    except sindri.SindriError as e:
        flash(request, "error", str(e))
    return _volver()


@router.post("/{tarea_id}/retirar/")
def retirar(request: Request, tarea_id: str):
    try:
        sindri.retirar(tarea_id)
        flash(request, "success", "Tarea retirada de Sindri: vuelve a estar por facturar.")
    except sindri.SindriError as e:
        flash(request, "error", str(e))
    return _volver()
