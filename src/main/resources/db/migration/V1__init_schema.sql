-- =========================================================
--  MULTI-TENANT (una BD / un esquema) con RLS
--  - PK compuesta (tenant_id, id) en tablas por tenant
--  - TODAS las FKs hacia tablas por tenant son compuestas
--  - Sin expresiones en UNIQUE (uso de CREATE UNIQUE INDEX)
-- =========================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;

-- ======================
-- Tipos
-- ======================
CREATE TYPE doc_status    AS ENUM ('BORRADOR','EMITIDA','PAGADA','RECIBIDA','ANULADA');
CREATE TYPE inv_move_type AS ENUM ('COMPRA','VENTA','AJUSTE','TRASLADO');
CREATE TYPE pago_metodo   AS ENUM ('EFECTIVO','TARJETA','TRANSFERENCIA','CHEQUE','OTRO');
CREATE TYPE caja_tx_tipo  AS ENUM ('APERTURA','VENTA_PAGO','CLIENTE_ABONO','PROVEEDOR_PAGO','EGRESO','INGRESO','AJUSTE_CIERRE');
CREATE TYPE doc_ref_tipo  AS ENUM ('VENTA','COMPRA','AJUSTE','TRASLADO','DEVOLUCION');
CREATE TYPE fin_status    AS ENUM ('PENDIENTE','PARCIAL','SALDADO','VENCIDO');

-- ======================
-- Núcleo multi-tenant
-- ======================
CREATE TABLE tenants (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT   NOT NULL,
  slug       CITEXT UNIQUE NOT NULL,         -- ej: "ferreteria-ramirez"
  plan       TEXT   NOT NULL DEFAULT 'basic',
  status     TEXT   NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Usuarios globales
CREATE TABLE usuario (
  id              BIGSERIAL PRIMARY KEY,
  nombre          TEXT NOT NULL,
  email           CITEXT UNIQUE NOT NULL,
  hash_password   TEXT NOT NULL,
  telefono        TEXT,
  activo          BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Membresías usuario↔tenant (N:M)
CREATE TABLE tenant_memberships (
  tenant_id  UUID   NOT NULL REFERENCES tenants(id),
  usuario_id BIGINT NOT NULL REFERENCES usuario(id),
  role TEXT NOT NULL DEFAULT 'admin',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, usuario_id)
);

-- ======================
-- Seguridad / permisos (globales)
-- ======================
CREATE TABLE rol (
  id BIGSERIAL PRIMARY KEY,
  nombre TEXT UNIQUE NOT NULL,
  descripcion TEXT
);

CREATE TABLE permiso (
  id BIGSERIAL PRIMARY KEY,
  clave TEXT UNIQUE NOT NULL,     -- p.ej. INVENTARIO.COSTO.VER
  descripcion TEXT
);

CREATE TABLE usuario_rol (
  usuario_id BIGINT REFERENCES usuario(id),
  rol_id     BIGINT REFERENCES rol(id),
  PRIMARY KEY (usuario_id, rol_id)
);

CREATE TABLE rol_permiso (
  rol_id     BIGINT REFERENCES rol(id),
  permiso_id BIGINT REFERENCES permiso(id),
  PRIMARY KEY (rol_id, permiso_id)
);

CREATE TABLE password_reset_token (
  id BIGSERIAL PRIMARY KEY,
  usuario_id BIGINT NOT NULL REFERENCES usuario(id),
  token UUID NOT NULL UNIQUE,
  expira_en TIMESTAMPTZ NOT NULL,
  usado BOOLEAN NOT NULL DEFAULT FALSE,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ======================
-- Catálogos por tenant
-- ======================
CREATE TABLE sucursal (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre TEXT NOT NULL,
  direccion TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id)
);

CREATE TABLE caja (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sucursal_id BIGINT NOT NULL,
  nombre TEXT NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, sucursal_id) REFERENCES sucursal(tenant_id, id)
);

CREATE TABLE almacen (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sucursal_id BIGINT NOT NULL,
  nombre TEXT NOT NULL,
  ubicacion TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, sucursal_id) REFERENCES sucursal(tenant_id, id)
);

-- Series/folios
CREATE TABLE documento_serie (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sucursal_id BIGINT NOT NULL,
  doc_tipo doc_ref_tipo NOT NULL,
  serie TEXT NOT NULL,
  proximo_numero BIGINT NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, sucursal_id) REFERENCES sucursal(tenant_id, id),
  UNIQUE (tenant_id, sucursal_id, doc_tipo, serie)
);

-- Impuestos
CREATE TABLE impuesto (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre TEXT NOT NULL,
  tasa NUMERIC(6,4) NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX uq_impuesto_nombre_tenant
  ON impuesto (tenant_id, lower(nombre));

-- Categorías
CREATE TABLE categoria (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre TEXT NOT NULL,
  padre_id BIGINT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, padre_id) REFERENCES categoria(tenant_id, id),
  CONSTRAINT ck_categoria_no_autoreferencia CHECK (padre_id IS NULL OR padre_id <> id)
);
CREATE UNIQUE INDEX uq_categoria_nombre_tenant
  ON categoria (tenant_id, lower(nombre));

-- Unidad de medida (GLOBAL)
CREATE TABLE uom (
  id BIGSERIAL PRIMARY KEY,
  codigo TEXT UNIQUE NOT NULL,
  nombre TEXT NOT NULL
);

-- Productos
CREATE TABLE producto (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sku TEXT NOT NULL,
  nombre TEXT NOT NULL,
  categoria_id BIGINT,                         -- FK compuesta abajo
  uom_base_id BIGINT NOT NULL REFERENCES uom(id),
  precio_venta NUMERIC(14,4) NOT NULL DEFAULT 0,
  costo        NUMERIC(14,4) NOT NULL DEFAULT 0,
  impuesto_id BIGINT,                          -- FK compuesta abajo
  stock_min NUMERIC(14,4) NOT NULL DEFAULT 0,
  stock_max NUMERIC(14,4) NOT NULL DEFAULT 0,
  ubicacion TEXT,
  imagen_url TEXT,
  descripcion TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, sku),
  FOREIGN KEY (tenant_id, categoria_id) REFERENCES categoria(tenant_id, id),
  FOREIGN KEY (tenant_id, impuesto_id)  REFERENCES impuesto(tenant_id, id)
);
CREATE INDEX idx_producto_cat        ON producto(tenant_id, categoria_id);
CREATE INDEX idx_producto_impuesto   ON producto(tenant_id, impuesto_id);
CREATE INDEX idx_producto_uom_base   ON producto(uom_base_id);

-- Conversiones por producto
CREATE TABLE producto_uom_conv (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  producto_id BIGINT NOT NULL,
  uom_id BIGINT NOT NULL REFERENCES uom(id),
  factor NUMERIC(14,6) NOT NULL,
  peso NUMERIC(14,6),
  volumen NUMERIC(14,6),
  empaque TEXT,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, producto_id, uom_id),
  FOREIGN KEY (tenant_id, producto_id) REFERENCES producto(tenant_id, id)
);

-- Proveedores
CREATE TABLE proveedor (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre_legal TEXT NOT NULL,
  nit TEXT,
  telefono TEXT,
  correo TEXT,
  direccion TEXT,
  contacto TEXT,
  forma_pago TEXT,
  limite_credito NUMERIC(14,2) DEFAULT 0,
  banco TEXT,
  cuenta TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  ciudad TEXT,
  pais TEXT,
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX uq_proveedor_nombre_tenant
  ON proveedor (tenant_id, lower(nombre_legal));

CREATE TABLE producto_proveedor (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  producto_id  BIGINT NOT NULL,
  proveedor_id BIGINT NOT NULL,
  es_preferente BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (tenant_id, producto_id, proveedor_id),
  FOREIGN KEY (tenant_id, producto_id)  REFERENCES producto(tenant_id, id),
  FOREIGN KEY (tenant_id, proveedor_id) REFERENCES proveedor(tenant_id, id)
);
CREATE UNIQUE INDEX uq_prod_prov_preferente
  ON producto_proveedor(tenant_id, producto_id)
  WHERE es_preferente;

-- ======================
-- Clientes / categorías
-- ======================
CREATE TABLE cliente_categoria (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre TEXT NOT NULL,
  descuento_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
  descripcion TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX uq_cliente_cat_nombre_tenant
  ON cliente_categoria (tenant_id, lower(nombre));

CREATE TABLE cliente (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  nombre TEXT NOT NULL,
  nit TEXT,
  telefono TEXT,
  correo TEXT,
  direccion TEXT,
  categoria_id BIGINT,
  limite_credito NUMERIC(14,2) DEFAULT 0,
  banco TEXT,
  cuenta TEXT,
  activo BOOLEAN NOT NULL DEFAULT TRUE,
  ciudad TEXT,
  pais TEXT,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, categoria_id) REFERENCES cliente_categoria(tenant_id, id)
);
CREATE UNIQUE INDEX uq_cliente_nombre_nit_tenant
  ON cliente (tenant_id, lower(nombre), coalesce(nit,''));
CREATE INDEX idx_cliente_categoria ON cliente(tenant_id, categoria_id);

-- ======================
-- Documentos / inventario
-- ======================
CREATE TABLE documento_ref (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  doc_tipo doc_ref_tipo NOT NULL,
  doc_id BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, doc_tipo, doc_id)
);

CREATE TABLE inventario_movimiento (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  producto_id BIGINT NOT NULL,
  tipo inv_move_type NOT NULL,
  cantidad NUMERIC(14,4) NOT NULL,
  almacen_origen_id  BIGINT,
  almacen_destino_id BIGINT,
  doc_ref_id BIGINT,
  motivo TEXT,
  usuario_id BIGINT REFERENCES usuario(id),
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, producto_id)        REFERENCES producto(tenant_id, id),
  FOREIGN KEY (tenant_id, almacen_origen_id)  REFERENCES almacen(tenant_id, id),
  FOREIGN KEY (tenant_id, almacen_destino_id) REFERENCES almacen(tenant_id, id),
  FOREIGN KEY (tenant_id, doc_ref_id)         REFERENCES documento_ref(tenant_id, id),
  CHECK (
    (tipo='TRASLADO' AND almacen_origen_id IS NOT NULL AND almacen_destino_id IS NOT NULL)
    OR (tipo<>'TRASLADO')
  )
);
CREATE INDEX idx_inv_mov_producto_fecha ON inventario_movimiento (tenant_id, producto_id, fecha);
CREATE INDEX idx_inv_mov_docref         ON inventario_movimiento (tenant_id, doc_ref_id);
CREATE INDEX idx_mov_producto           ON inventario_movimiento (tenant_id, producto_id);
CREATE INDEX idx_mov_almacen_origen     ON inventario_movimiento (tenant_id, almacen_origen_id);
CREATE INDEX idx_mov_almacen_dest       ON inventario_movimiento (tenant_id, almacen_destino_id);
CREATE INDEX idx_mov_fecha              ON inventario_movimiento (tenant_id, fecha);

ALTER TABLE inventario_movimiento
  ADD CONSTRAINT ck_mov_compra
  CHECK (
    (tipo <> 'COMPRA')
    OR (tipo = 'COMPRA' AND almacen_destino_id IS NOT NULL AND almacen_origen_id IS NULL AND cantidad > 0)
  );

ALTER TABLE inventario_movimiento
  ADD CONSTRAINT ck_mov_venta
  CHECK (
    (tipo <> 'VENTA')
    OR (tipo = 'VENTA' AND almacen_origen_id IS NOT NULL AND almacen_destino_id IS NULL AND cantidad > 0)
  );

ALTER TABLE inventario_movimiento
  ADD CONSTRAINT ck_mov_ajuste
  CHECK (
    (tipo <> 'AJUSTE')
    OR (
      tipo = 'AJUSTE' AND
      (
        (almacen_destino_id IS NOT NULL AND almacen_origen_id IS NULL) OR
        (almacen_origen_id IS NOT NULL AND almacen_destino_id IS NULL)
      )
      AND cantidad > 0
    )
  );

-- ======================
-- Ventas / CxC / Caja
-- ======================
CREATE TABLE venta (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sucursal_id BIGINT NOT NULL,
  cliente_id BIGINT,
  usuario_id BIGINT NOT NULL REFERENCES usuario(id),
  serie TEXT,
  numero BIGINT,
  estado doc_status NOT NULL DEFAULT 'BORRADOR',
  es_devolucion BOOLEAN NOT NULL DEFAULT FALSE,
  venta_padre_id BIGINT,
  subtotal NUMERIC(14,4) NOT NULL DEFAULT 0,
  impuesto_total NUMERIC(14,4) NOT NULL DEFAULT 0,
  total NUMERIC(14,4) NOT NULL DEFAULT 0,
  es_credito BOOLEAN NOT NULL DEFAULT FALSE,
  anulado_por BIGINT REFERENCES usuario(id),
  anulado_motivo TEXT,
  anulado_en TIMESTAMPTZ,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  documento_serie_id BIGINT,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, sucursal_id)       REFERENCES sucursal(tenant_id, id),
  FOREIGN KEY (tenant_id, cliente_id)        REFERENCES cliente(tenant_id, id),
  FOREIGN KEY (tenant_id, venta_padre_id)    REFERENCES venta(tenant_id, id),
  FOREIGN KEY (tenant_id, documento_serie_id)REFERENCES documento_serie(tenant_id, id),
  CONSTRAINT ck_venta_devolucion CHECK (
    (es_devolucion = TRUE  AND venta_padre_id IS NOT NULL) OR
    (es_devolucion = FALSE AND venta_padre_id IS NULL)
  ),
  CONSTRAINT ck_venta_numeracion CHECK (
    (estado IN ('BORRADOR')) OR (documento_serie_id IS NOT NULL AND numero IS NOT NULL)
  )
);
CREATE UNIQUE INDEX uq_venta_doc
  ON venta (tenant_id, sucursal_id, serie, numero) WHERE serie IS NOT NULL;
CREATE UNIQUE INDEX uq_venta_serie_num
  ON venta(tenant_id, documento_serie_id, numero) WHERE documento_serie_id IS NOT NULL;
CREATE INDEX idx_venta_fecha        ON venta (tenant_id, creado_en);
CREATE INDEX idx_venta_estado_fecha ON venta (tenant_id, estado, creado_en);
CREATE INDEX idx_venta_cliente      ON venta (tenant_id, cliente_id);

CREATE TABLE venta_det (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  venta_id BIGINT NOT NULL,
  producto_id BIGINT NOT NULL,
  uom_id BIGINT NOT NULL REFERENCES uom(id),
  cantidad NUMERIC(14,4) NOT NULL,
  precio_unitario NUMERIC(14,4) NOT NULL,
  descuento_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
  impuesto_id BIGINT,
  impuesto_monto NUMERIC(14,4) NOT NULL DEFAULT 0,
  total_linea NUMERIC(14,4) NOT NULL DEFAULT 0,
  uom_factor NUMERIC(14,6) NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, venta_id)    REFERENCES venta(tenant_id, id),
  FOREIGN KEY (tenant_id, producto_id) REFERENCES producto(tenant_id, id),
  FOREIGN KEY (tenant_id, impuesto_id) REFERENCES impuesto(tenant_id, id),
  CONSTRAINT ck_venta_det_montos_pos CHECK (cantidad > 0 AND precio_unitario >= 0 AND total_linea >= 0),
  CONSTRAINT ck_ventadet_uom_factor_pos CHECK (uom_factor > 0)
);
CREATE INDEX idx_ventadet_producto ON venta_det (tenant_id, producto_id);
CREATE INDEX idx_ventadet_venta    ON venta_det (tenant_id, venta_id);

-- Pagos de clientes (***sin*** REFERENCES simple)
CREATE TABLE pago_cliente (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  venta_id BIGINT,                 -- <- sin REFERENCES aquí
  cliente_id BIGINT NOT NULL,
  metodo pago_metodo NOT NULL,
  monto NUMERIC(14,2) NOT NULL,
  referencia TEXT,
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, venta_id)   REFERENCES venta(tenant_id, id),
  FOREIGN KEY (tenant_id, cliente_id) REFERENCES cliente(tenant_id, id),
  CONSTRAINT ck_pago_cliente_ref CHECK (cliente_id IS NOT NULL),
  CONSTRAINT ck_pago_cliente_monto_pos CHECK (monto > 0)
);

CREATE TABLE cxc_doc (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  venta_id BIGINT NOT NULL,
  cliente_id BIGINT NOT NULL,
  emitido_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  vence_en TIMESTAMPTZ,
  saldo NUMERIC(14,2) NOT NULL,
  estado fin_status NOT NULL DEFAULT 'PENDIENTE',
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, venta_id)   REFERENCES venta(tenant_id, id),
  FOREIGN KEY (tenant_id, cliente_id) REFERENCES cliente(tenant_id, id)
);
CREATE INDEX idx_cxc_cliente ON cxc_doc (tenant_id, cliente_id);

CREATE TABLE caja_sesion (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  caja_id BIGINT NOT NULL,
  usuario_id BIGINT NOT NULL REFERENCES usuario(id),
  estado TEXT NOT NULL DEFAULT 'ABIERTA',
  monto_inicial NUMERIC(14,2) NOT NULL DEFAULT 0,
  abierto_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  cerrado_en TIMESTAMPTZ,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, caja_id) REFERENCES caja(tenant_id, id)
);
CREATE UNIQUE INDEX uq_caja_abierta_por_caja
  ON caja_sesion(tenant_id, caja_id)
  WHERE estado = 'ABIERTA' AND cerrado_en IS NULL;

CREATE TABLE caja_transaccion (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  caja_sesion_id BIGINT NOT NULL,
  tipo caja_tx_tipo NOT NULL,
  metodo pago_metodo,
  monto NUMERIC(14,2) NOT NULL,
  referencia TEXT,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, caja_sesion_id) REFERENCES caja_sesion(tenant_id, id),
  CONSTRAINT ck_caja_tx_monto_pos CHECK (monto >= 0)
);
CREATE INDEX idx_caja_sesion_caja ON caja_sesion (tenant_id, caja_id);
CREATE INDEX idx_caja_tx_sesion   ON caja_transaccion (tenant_id, caja_sesion_id);

CREATE TABLE cxc_pago (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  cxc_id BIGINT NOT NULL,
  monto NUMERIC(14,2) NOT NULL,
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  caja_tx_id BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, cxc_id)     REFERENCES cxc_doc(tenant_id, id),
  FOREIGN KEY (tenant_id, caja_tx_id) REFERENCES caja_transaccion(tenant_id, id),
  CONSTRAINT ck_cxc_pago_monto_pos CHECK (monto > 0)
);

-- ======================
-- Compras / CxP
-- ======================
CREATE TABLE compra (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  sucursal_id BIGINT NOT NULL,
  proveedor_id BIGINT NOT NULL,
  usuario_id BIGINT NOT NULL REFERENCES usuario(id),
  serie TEXT,
  numero BIGINT,
  estado doc_status NOT NULL DEFAULT 'BORRADOR',
  subtotal NUMERIC(14,4) NOT NULL DEFAULT 0,
  impuesto_total NUMERIC(14,4) NOT NULL DEFAULT 0,
  total NUMERIC(14,4) NOT NULL DEFAULT 0,
  es_credito BOOLEAN NOT NULL DEFAULT FALSE,
  anulado_por BIGINT REFERENCES usuario(id),
  anulado_motivo TEXT,
  anulado_en TIMESTAMPTZ,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  documento_serie_id BIGINT,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, sucursal_id)  REFERENCES sucursal(tenant_id, id),
  FOREIGN KEY (tenant_id, proveedor_id) REFERENCES proveedor(tenant_id, id),
  FOREIGN KEY (tenant_id, documento_serie_id) REFERENCES documento_serie(tenant_id, id),
  CONSTRAINT ck_compra_numeracion CHECK (
    (estado IN ('BORRADOR')) OR (documento_serie_id IS NOT NULL AND numero IS NOT NULL)
  )
);
CREATE UNIQUE INDEX uq_compra_doc
  ON compra (tenant_id, sucursal_id, serie, numero) WHERE serie IS NOT NULL;
CREATE UNIQUE INDEX uq_compra_serie_num
  ON compra(tenant_id, documento_serie_id, numero) WHERE documento_serie_id IS NOT NULL;
CREATE INDEX idx_compra_estado_fecha ON compra (tenant_id, estado, creado_en);
CREATE INDEX idx_compra_proveedor    ON compra (tenant_id, proveedor_id);

CREATE TABLE compra_det (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  compra_id BIGINT NOT NULL,
  producto_id BIGINT NOT NULL,
  uom_id BIGINT NOT NULL REFERENCES uom(id),
  cantidad NUMERIC(14,4) NOT NULL,
  costo_unitario NUMERIC(14,4) NOT NULL,
  descuento_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
  impuesto_id BIGINT,
  impuesto_monto NUMERIC(14,4) NOT NULL DEFAULT 0,
  total_linea NUMERIC(14,4) NOT NULL DEFAULT 0,
  uom_factor NUMERIC(14,6) NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, compra_id)   REFERENCES compra(tenant_id, id),
  FOREIGN KEY (tenant_id, producto_id) REFERENCES producto(tenant_id, id),
  FOREIGN KEY (tenant_id, impuesto_id) REFERENCES impuesto(tenant_id, id),
  CONSTRAINT ck_compra_det_montos_pos CHECK (cantidad > 0 AND costo_unitario >= 0 AND total_linea >= 0),
  CONSTRAINT ck_compradet_uom_factor_pos CHECK (uom_factor > 0)
);
CREATE INDEX idx_compradet_compra  ON compra_det (tenant_id, compra_id);

-- Pagos a proveedores (***sin*** REFERENCES simple)
CREATE TABLE pago_proveedor (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  compra_id BIGINT,                -- <- sin REFERENCES aquí
  proveedor_id BIGINT NOT NULL,
  metodo pago_metodo NOT NULL,
  monto NUMERIC(14,2) NOT NULL,
  referencia TEXT,
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, compra_id)    REFERENCES compra(tenant_id, id),
  FOREIGN KEY (tenant_id, proveedor_id) REFERENCES proveedor(tenant_id, id),
  CONSTRAINT ck_pago_proveedor_ref CHECK (proveedor_id IS NOT NULL),
  CONSTRAINT ck_pago_proveedor_monto_pos CHECK (monto > 0)
);

-- Cuentas por pagar
CREATE TABLE cxp_doc (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  compra_id BIGINT NOT NULL,
  proveedor_id BIGINT NOT NULL,
  emitido_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  vence_en TIMESTAMPTZ,
  saldo NUMERIC(14,2) NOT NULL,
  estado fin_status NOT NULL DEFAULT 'PENDIENTE',
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, compra_id)    REFERENCES compra(tenant_id, id),
  FOREIGN KEY (tenant_id, proveedor_id) REFERENCES proveedor(tenant_id, id)
);
CREATE INDEX idx_cxp_proveedor ON cxp_doc (tenant_id, proveedor_id);

CREATE TABLE cxp_pago (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  cxp_id BIGINT NOT NULL,
  monto NUMERIC(14,2) NOT NULL,
  fecha TIMESTAMPTZ NOT NULL DEFAULT now(),
  caja_tx_id BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, cxp_id)     REFERENCES cxp_doc(tenant_id, id),
  FOREIGN KEY (tenant_id, caja_tx_id) REFERENCES caja_transaccion(tenant_id, id),
  CONSTRAINT ck_cxp_pago_monto_pos CHECK (monto > 0)
);

-- ======================
-- Auditoría
-- ======================
CREATE TABLE auditoria_log (
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  id BIGSERIAL,
  usuario_id BIGINT REFERENCES usuario(id),
  accion TEXT NOT NULL,
  entidad TEXT NOT NULL,
  entidad_id BIGINT,
  detalle JSONB,
  ip TEXT,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id)
);

-- ======================
-- Vista de stock (scoped por tenant)
-- ======================
CREATE OR REPLACE VIEW vw_stock_por_almacen AS
SELECT
  p.tenant_id,
  p.id AS producto_id,
  a.id AS almacen_id,
  COALESCE(SUM(
    CASE
      WHEN m.tipo='COMPRA'   AND m.almacen_destino_id=a.id THEN  m.cantidad
      WHEN m.tipo='VENTA'    AND m.almacen_origen_id=a.id  THEN -m.cantidad
      WHEN m.tipo='AJUSTE'   AND m.almacen_destino_id=a.id THEN  m.cantidad
      WHEN m.tipo='AJUSTE'   AND m.almacen_origen_id=a.id  THEN -m.cantidad
      WHEN m.tipo='TRASLADO' AND m.almacen_destino_id=a.id THEN  m.cantidad
      WHEN m.tipo='TRASLADO' AND m.almacen_origen_id=a.id  THEN -m.cantidad
      ELSE 0
    END
  ),0) AS stock
FROM producto p
JOIN almacen a
  ON a.tenant_id = p.tenant_id
LEFT JOIN inventario_movimiento m
  ON m.tenant_id = p.tenant_id AND m.producto_id = p.id
GROUP BY p.tenant_id, p.id, a.id;

-- =========================================================
-- Row-Level Security (RLS)
-- =========================================================
CREATE OR REPLACE FUNCTION set_tenant(_tenant UUID)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.tenant_id', _tenant::text, true);
END; $$;

CREATE OR REPLACE FUNCTION rls_tenant_match(tenant UUID)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT tenant::text = current_setting('app.tenant_id', true)
$$;

DO $$
DECLARE
  t TEXT;
  tables TEXT[] := ARRAY[
    'sucursal','caja','almacen','documento_serie','impuesto','categoria',
    'producto','producto_uom_conv','proveedor','producto_proveedor',
    'cliente_categoria','cliente',
    'documento_ref','inventario_movimiento',
    'venta','venta_det','pago_cliente','cxc_doc','caja_sesion','caja_transaccion','cxc_pago',
    'compra','compra_det','pago_proveedor','cxp_doc','cxp_pago',
    'auditoria_log'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format(
      'CREATE POLICY %I_rls_tenant ON %I USING (rls_tenant_match(%I.tenant_id));',
      t, t, t
    );
    EXECUTE format(
      'CREATE POLICY %I_rls_tenant_ins ON %I FOR INSERT WITH CHECK (rls_tenant_match(%I.tenant_id));',
      t, t, t
    );
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;', t);
  END LOOP;
END $$;

-- Índice útil adicional
CREATE INDEX idx_docref_tipo_id ON documento_ref(tenant_id, doc_tipo, doc_id);

-- (Opcional) Datos de prueba
-- INSERT INTO tenants (name, slug) VALUES ('Demo', 'demo');
-- SELECT set_tenant((SELECT id FROM tenants WHERE slug='demo'));
-- INSERT INTO sucursal (tenant_id, nombre) VALUES ((SELECT id FROM tenants WHERE slug='demo'), 'Central');
