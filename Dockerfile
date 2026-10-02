FROM nginx:alpine

COPY app/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80