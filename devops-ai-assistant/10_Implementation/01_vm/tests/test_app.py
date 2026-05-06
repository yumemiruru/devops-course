# Імпортуємо Flask-застосунок із головного файлу проєкту
from app import app


def test_health_endpoint():
    # Створюємо тестового клієнта Flask без запуску реального сервера
    client = app.test_client()

    # Імітуємо HTTP-запит до endpoint /health
    response = client.get("/health")

    # Перевіряємо, що endpoint відповів успішно
    assert response.status_code == 200

    # Перевіряємо, що застосунок повернув очікуваний JSON
    assert response.get_json() == {"status": "ok"}