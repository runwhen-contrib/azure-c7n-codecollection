import os
from jinja2 import Environment, FileSystemLoader

def generate_policy(template_path, **kargs):

    if not os.path.isfile(template_path):
        raise FileNotFoundError(f"Template file not found: {template_path}")
    
    template_dir = os.path.dirname(template_path) if os.path.dirname(template_path) else os.environ.get("CODEBUNDLE_TEMP_DIR")
    template_file   = os.path.split(template_path)[-1]
    jinja_env       = Environment(loader=FileSystemLoader(os.path.dirname(template_path)))

    if "tags" in kargs and kargs["tags"] not in (None, "", "''", '""'):
        kargs["tags"] = kargs["tags"].strip('"').strip("'").replace(" ","").split(",")
    else:
        kargs["tags"] = []

    try:
        template = jinja_env.get_template(template_file)
    except Exception as e:
        raise Exception(f"Error loading template: {e}")
    
    try:
        rendered_policy = template.render(kargs)
        policy_file_path = os.path.join(template_dir, f'{template_file.split(".")[0]}.yaml')

        with open(policy_file_path, 'w') as output_file:
            output_file.write(rendered_policy)
    except Exception as e:
        raise Exception(f"Error rendering template: {e}")