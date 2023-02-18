FROM python:3
COPY requirements.txt /requirements.txt
RUN pip install -r requirements.txt
COPY action.yml /action.yml
COPY main.py /main.py
CMD ["python", "/main.py"]
