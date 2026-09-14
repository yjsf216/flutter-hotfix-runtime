// Fix: shipping is charged once for the whole order.
int totalCents(int unitCents, int quantity, int shippingCents) =>
    unitCents * quantity + shippingCents;
