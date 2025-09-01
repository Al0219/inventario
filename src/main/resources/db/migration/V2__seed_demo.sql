INSERT INTO tenants (name, slug) VALUES ('Demo', 'demo');
SELECT set_tenant((SELECT id FROM tenants WHERE slug='demo'));
INSERT INTO sucursal (tenant_id, nombre) VALUES (current_setting('app.tenant_id')::uuid, 'Central');
INSERT INTO almacen  (tenant_id, sucursal_id, nombre) VALUES (current_setting('app.tenant_id')::uuid, 1, 'Principal');
