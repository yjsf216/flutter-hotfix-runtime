// Intentional baseline defect: shipping is charged once for every item.
int totalCents(int unitCents, int quantity, int shippingCents) =>
    (unitCents + shippingCents) * quantity;
