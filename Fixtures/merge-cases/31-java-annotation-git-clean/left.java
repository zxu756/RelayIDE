public class Shape {
    private final double side;

    public Shape(double side) {
        this.side = side;
    }

    public double area() {
        return side * side;
    }

    @Override
    public String toString() {
        return "Shape(" + side + ")";
    }
}
