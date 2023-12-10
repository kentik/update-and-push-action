FROM alpine:latest
RUN apk add --no-cache git openssh-client rsync python3
RUN ls -lrt /usr/lib/python3.11/ && rm -rf /usr/lib/python3.11/EXTERNALLY-MANAGED
RUN python3 -m ensurepip
RUN pip3 install --no-cache --upgrade pip setuptools
COPY requirements.txt /requirements.txt
RUN pip3 install -r requirements.txt
COPY action.yml /action.yml
COPY main.py /main.py
CMD ["python3", "/main.py"]
